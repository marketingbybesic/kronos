#if os(macOS)
// Full control: list_labels, create_label, update_label, create_project, update_project,
// create_area, update_area, delete_area, move_task. All but list_labels need the per-agent scope
// `write.all` (see MCPDispatcher+Scopes). None of them deletes a project or a label (the store has
// no such operation for a machine to call): a project is archived instead.
//
// Structure edits register undo steps in the store; a machine batch must not bury the person's own
// undo history, so every write here runs inside `withoutUndo` like the task tools do.

import Foundation

extension MCPDispatcher {

    // MARK: - Shared

    /// Runs a store write without leaving an undo step behind (the person's Cmd-Z stays theirs).
    private func quietly<T>(_ body: () -> T) -> T {
        if let concrete = store as? TaskStore { return concrete.withoutUndo(body) }
        return body()
    }

    private func object(_ arguments: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] ?? [:]
    }

    /// A trimmed, non-empty name of at most `max` characters; absent is an error only when `required`.
    private func textName(_ obj: [String: Any], max: Int, required: Bool) -> (value: String?, error: MCPToolOutcome?) {
        guard let raw = obj["name"] else {
            return required ? (nil, .error(.invalidParams, message: "name is required", data: ["field": "name"])) : (nil, nil)
        }
        guard let s = raw as? String else { return (nil, .error(.invalidParams, message: "name must be a string", data: ["field": "name"])) }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return (nil, .error(.invalidParams, message: "name must not be empty", data: ["field": "name"])) }
        if t.count > max { return (nil, .error(.invalidParams, message: "name is \(t.count) characters; the limit is \(max)", data: ["field": "name"])) }
        return (t, nil)
    }

    private func colorValue(_ obj: [String: Any]) -> (value: String?, error: MCPToolOutcome?) {
        guard let raw = obj["colorHex"] else { return (nil, nil) }
        guard let s = raw as? String, let hex = TaskStore.normalizedHex(s) else {
            return (nil, .error(.invalidParams, message: "colorHex must be #RRGGBB", data: ["field": "colorHex"]))
        }
        return (hex, nil)
    }

    /// A string or an explicit null. `present` = the key was sent (null clears).
    private func optionalText(_ obj: [String: Any], _ key: String, max: Int) -> (present: Bool, value: String?, error: MCPToolOutcome?) {
        guard let raw = obj[key] else { return (false, nil, nil) }
        if raw is NSNull { return (true, nil, nil) }
        guard let s = raw as? String else { return (true, nil, .error(.invalidParams, message: "\(key) must be a string or null", data: ["field": key])) }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count > max { return (true, nil, .error(.invalidParams, message: "\(key) is longer than \(max) characters", data: ["field": key])) }
        return (true, t.isEmpty ? nil : t, nil)
    }

    private func requiredID(_ obj: [String: Any], _ key: String) -> (value: UUID?, error: MCPToolOutcome?) {
        guard let raw = obj[key] else { return (nil, .error(.invalidParams, message: "\(key) is required", data: ["field": key])) }
        guard let s = raw as? String, let id = UUID(uuidString: s) else {
            return (nil, .error(.invalidParams, message: "\(key) must be a UUID", data: ["field": key]))
        }
        return (id, nil)
    }

    private func findArea(_ id: UUID) -> KArea? { store.allAreas().first { $0.id == id } }
    private func findProject(_ id: UUID) -> KProject? { store.allProjects(includeArchived: true).first { $0.id == id } }

    private func projectDTO(_ p: KProject) -> MCPProjectDTO {
        let mine = store.allTasks().filter { $0.projectID == p.id }
        return MCPProjectDTO(id: p.id, name: p.name, areaID: p.area?.id, areaName: p.area?.name, icon: p.icon, emoji: p.emoji,
                             colorHex: p.colorHex, isArchived: p.isArchived, sortIndex: p.sortIndex,
                             openTaskCount: mine.filter { !KStatus.closed.contains($0.status) }.count, totalTaskCount: mine.count)
    }

    private func areaDTO(_ a: KArea) -> MCPAreaDTO {
        let live = store.allTasks()
        let projects = a.orderedProjects
        let ids = Set(projects.map(\.id))
        let open = live.filter { t in
            !KStatus.closed.contains(t.status) && (t.areaID == a.id || t.projectID.map(ids.contains) == true)
        }.count
        return MCPAreaDTO(id: a.id, name: a.name, colorHex: a.colorHex, icon: a.icon, sortIndex: a.sortIndex,
                          projects: projects.map { MCPAreaDTO.ProjectRef(id: $0.id, name: $0.name) }, openTaskCount: open)
    }

    struct LabelDTO: Encodable {
        let id: UUID
        let name: String
        let colorHex: String
        let openTaskCount: Int
    }

    private func labelDTO(_ l: KLabel, live: [KTask]) -> LabelDTO {
        let open = live.filter { t in !KStatus.closed.contains(t.status) && (t.labels ?? []).contains { $0.id == l.id } }.count
        return LabelDTO(id: l.id, name: l.name, colorHex: l.colorHex, openTaskCount: open)
    }

    // MARK: - Labels

    func listLabels(_ arguments: Data) -> MCPToolOutcome {
        let live = store.allTasksIncludingSubtasks()
        struct Result: Encodable { let labels: [LabelDTO]; let total: Int }
        let dtos = store.labels().map { labelDTO($0, live: live) }
        return .ok(Result(labels: dtos, total: dtos.count))
    }

    func createLabel(_ arguments: Data) -> MCPToolOutcome {
        let obj = object(arguments)
        let n = textName(obj, max: 80, required: true); if let e = n.error { return e }
        let c = colorValue(obj); if let e = c.error { return e }
        let wanted = n.value ?? ""
        let key = KLabel(name: wanted).mergeKey
        let existing = store.labels().first { $0.mergeKey == key }
        let label = existing ?? quietly { store.label(named: wanted) }
        if existing == nil, let hex = c.value, let concrete = store as? TaskStore {
            _ = concrete.withoutUndo { concrete.setLabelColor(label.id, hex: hex) }
        }
        struct Result: Encodable { let created: Bool; let label: LabelDTO }
        return .ok(Result(created: existing == nil, label: labelDTO(label, live: store.allTasksIncludingSubtasks())))
    }

    func updateLabel(_ arguments: Data) -> MCPToolOutcome {
        let obj = object(arguments)
        let id = requiredID(obj, "id"); if let e = id.error { return e }
        let n = textName(obj, max: 80, required: false); if let e = n.error { return e }
        let c = colorValue(obj); if let e = c.error { return e }
        guard let labelID = id.value else { return .error(.invalidParams, message: "id is required") }
        guard n.value != nil || c.value != nil else {
            return .error(.invalidParams, message: "give name or colorHex", data: ["field": "name"])
        }
        guard let concrete = store as? TaskStore else {
            return .error(.internalError, message: "this store cannot edit labels")
        }
        guard concrete.label(id: labelID) != nil else { return .error(.notFound, message: "no label \(labelID)") }
        if let newName = n.value {
            switch concrete.withoutUndo({ concrete.renameLabel(labelID, to: newName) }) {
            case .renamed, .unchanged: break
            case .empty: return .error(.invalidParams, message: "name must not be empty", data: ["field": "name"])
            case .duplicate: return .error(.conflict, message: "another label is already called \(newName)", data: ["field": "name"])
            case .notFound: return .error(.notFound, message: "no label \(labelID)")
            }
        }
        if let hex = c.value { _ = concrete.withoutUndo { concrete.setLabelColor(labelID, hex: hex) } }
        guard let label = concrete.label(id: labelID) else { return .error(.internalError, message: "label vanished") }
        struct Result: Encodable { let updated: Bool; let label: LabelDTO }
        return .ok(Result(updated: true, label: labelDTO(label, live: store.allTasksIncludingSubtasks())))
    }

    // MARK: - Projects

    func createProject(_ arguments: Data) -> MCPToolOutcome {
        let obj = object(arguments)
        let n = textName(obj, max: 120, required: true); if let e = n.error { return e }
        let c = colorValue(obj); if let e = c.error { return e }
        let icon = optionalText(obj, "icon", max: 60); if let e = icon.error { return e }
        let emoji = optionalText(obj, "emoji", max: 8); if let e = emoji.error { return e }
        var parent: KArea?
        if obj["areaID"] != nil {
            let a = requiredID(obj, "areaID"); if let e = a.error { return e }
            guard let aid = a.value, let found = findArea(aid) else {
                return .error(.notFound, message: "no area \(a.value?.uuidString ?? "")", data: ["areaID": a.value?.uuidString ?? ""])
            }
            parent = found
        }
        let made = quietly { () -> KProject in
            let p = store.createProject(name: n.value ?? "", colorHex: c.value ?? "#8224E3", icon: icon.value, area: parent)
            if let e = emoji.value { store.updateProject(p.id, name: nil, colorHex: nil, icon: nil, emoji: .some(e)) }
            return p
        }
        struct Result: Encodable { let created: Bool; let project: MCPProjectDTO }
        return .ok(Result(created: true, project: projectDTO(findProject(made.id) ?? made)))
    }

    func updateProject(_ arguments: Data) -> MCPToolOutcome {
        let obj = object(arguments)
        let id = requiredID(obj, "id"); if let e = id.error { return e }
        let n = textName(obj, max: 120, required: false); if let e = n.error { return e }
        let c = colorValue(obj); if let e = c.error { return e }
        let icon = optionalText(obj, "icon", max: 60); if let e = icon.error { return e }
        let emoji = optionalText(obj, "emoji", max: 8); if let e = emoji.error { return e }
        var archived: Bool?
        if let raw = obj["archived"] {
            guard let b = raw as? Bool else { return .error(.invalidParams, message: "archived must be true or false", data: ["field": "archived"]) }
            archived = b
        }
        var moveTo: KArea??
        if let raw = obj["areaID"] {
            if raw is NSNull { moveTo = .some(nil) } else {
                let a = requiredID(obj, "areaID"); if let e = a.error { return e }
                guard let aid = a.value, let found = findArea(aid) else {
                    return .error(.notFound, message: "no area \(a.value?.uuidString ?? "")", data: ["areaID": a.value?.uuidString ?? ""])
                }
                moveTo = .some(found)
            }
        }
        guard let pid = id.value, let existing = findProject(pid) else { return .error(.notFound, message: "no project \(id.value?.uuidString ?? "")") }
        let touched = n.value != nil || c.value != nil || icon.present || emoji.present || archived != nil || moveTo != nil
        guard touched else { return .error(.invalidParams, message: "nothing to change", data: ["field": "id"]) }
        quietly {
            if n.value != nil || c.value != nil || icon.present || emoji.present {
                store.updateProject(existing.id, name: n.value, colorHex: c.value,
                                    icon: icon.present ? .some(icon.value) : nil,
                                    emoji: emoji.present ? .some(emoji.value) : nil)
            }
            if let target = moveTo { store.moveProject(existing.id, toArea: target) }
            if let a = archived, a != existing.isArchived {
                if a { store.archiveProject(existing.id) } else { store.restoreProject(existing.id) }
            }
        }
        guard let final = findProject(existing.id) else { return .error(.internalError, message: "project vanished") }
        struct Result: Encodable { let updated: Bool; let project: MCPProjectDTO }
        return .ok(Result(updated: true, project: projectDTO(final)))
    }

    // MARK: - Areas

    func createArea(_ arguments: Data) -> MCPToolOutcome {
        let obj = object(arguments)
        let n = textName(obj, max: 120, required: true); if let e = n.error { return e }
        let c = colorValue(obj); if let e = c.error { return e }
        let icon = optionalText(obj, "icon", max: 60); if let e = icon.error { return e }
        let made = quietly { store.createArea(name: n.value ?? "", colorHex: c.value ?? "#8B8B93", icon: icon.value ?? "square.grid.2x2") }
        struct Result: Encodable { let created: Bool; let area: MCPAreaDTO }
        return .ok(Result(created: true, area: areaDTO(findArea(made.id) ?? made)))
    }

    func updateArea(_ arguments: Data) -> MCPToolOutcome {
        let obj = object(arguments)
        let id = requiredID(obj, "id"); if let e = id.error { return e }
        let n = textName(obj, max: 120, required: false); if let e = n.error { return e }
        let c = colorValue(obj); if let e = c.error { return e }
        let icon = optionalText(obj, "icon", max: 60); if let e = icon.error { return e }
        if obj["icon"] is NSNull { return .error(.invalidParams, message: "icon cannot be cleared", data: ["field": "icon"]) }
        guard n.value != nil || c.value != nil || icon.value != nil else {
            return .error(.invalidParams, message: "nothing to change", data: ["field": "id"])
        }
        guard let aid = id.value, let existing = findArea(aid) else { return .error(.notFound, message: "no area \(id.value?.uuidString ?? "")") }
        quietly {
            if let newName = n.value { store.renameArea(existing.id, name: newName) }
            if c.value != nil || icon.value != nil { store.updateArea(existing.id, colorHex: c.value, icon: icon.value) }
        }
        guard let final = findArea(existing.id) else { return .error(.internalError, message: "area vanished") }
        struct Result: Encodable { let updated: Bool; let area: MCPAreaDTO }
        return .ok(Result(updated: true, area: areaDTO(final)))
    }

    func deleteArea(_ arguments: Data) -> MCPToolOutcome {
        let obj = object(arguments)
        let id = requiredID(obj, "id"); if let e = id.error { return e }
        guard obj["confirm"] as? Bool == true else { return .error(.invalidParams, message: "confirm must be true", data: ["field": "confirm"]) }
        guard let aid = id.value, let existing = findArea(aid) else { return .error(.notFound, message: "no area \(id.value?.uuidString ?? "")") }
        let held = (existing.projects ?? []).count
        if held > 0 {
            return .error(.invalidState, message: "the area still holds \(held) project\(held == 1 ? "" : "s"); move or archive them first",
                          data: ["projects": held])
        }
        let outcome: Result<Void, Error> = quietly { Result { try store.deleteArea(existing) } }
        if case .failure(let error) = outcome {
            return .error(.invalidState, message: "the area could not be deleted: \(error)")
        }
        struct Done: Encodable { let deleted: Bool; let id: UUID }
        return .ok(Done(deleted: true, id: aid))
    }

    // MARK: - move_task

    func moveTask(_ arguments: Data) -> MCPToolOutcome {
        let obj = object(arguments)
        let id = requiredID(obj, "id"); if let e = id.error { return e }
        let hasProject = obj["project"] != nil, hasParent = obj["parentID"] != nil, hasBefore = obj["before"] != nil
        guard hasProject || hasParent || hasBefore else {
            return .error(.invalidParams, message: "give project, parentID or before", data: ["field": "project"])
        }
        guard let taskID = id.value, let t = store.task(taskID) else { return .error(.notFound, message: "no task \(id.value?.uuidString ?? "")") }

        var before: UUID?
        if hasBefore {
            let b = requiredID(obj, "before"); if let e = b.error { return e }
            before = b.value
        }
        var newParent: UUID??
        if hasParent {
            if obj["parentID"] is NSNull { newParent = .some(nil) } else {
                let p = requiredID(obj, "parentID"); if let e = p.error { return e }
                guard let pid = p.value, store.task(pid) != nil else {
                    return .error(.notFound, message: "no task \(p.value?.uuidString ?? "")", data: ["field": "parentID"])
                }
                newParent = .some(pid)
            }
        }
        var destination: KProject??
        if hasProject {
            if obj["project"] is NSNull { destination = .some(nil) } else {
                guard let text = obj["project"] as? String else {
                    return .error(.invalidParams, message: "project must be a name, an id or null", data: ["field": "project"])
                }
                guard let found = resolveProject(text) else { return .error(.notFound, message: "no project matching \(text)", data: ["value": text]) }
                destination = .some(found)
            }
        }
        if case .some(.some) = newParent, destination != nil {
            return .error(.invalidParams, message: "a subtask carries its parent's project; give project or parentID, not both")
        }
        if !hasParent, hasBefore {
            guard let parent = t.parentID else {
                return .error(.invalidParams, message: "before places a subtask among its siblings; this is a top-level task (use parentID to nest it)",
                              data: ["field": "before"])
            }
            guard let b = before, store.task(b)?.parentID == parent else {
                return .error(.invalidParams, message: "before must be a sibling subtask of the same parent", data: ["field": "before"])
            }
        }

        var failure: MCPToolOutcome?
        quietly {
            do {
                if let target = newParent {
                    switch target {
                    case .none:
                        if store.task(t.id)?.isSubtask == true { try store.setParentNoUndo(t.id, to: nil, at: .afterFormerParent) }
                    case .some(let pid):
                        try store.setParentNoUndo(t.id, to: pid, at: before.map { KNestPlacement.before($0) } ?? .end)
                    }
                } else if hasBefore, let parent = t.parentID, let b = before {
                    try store.setParentNoUndo(t.id, to: parent, at: .before(b))
                }
                if let p = destination { store.move(t.id, toProject: p) }
            } catch let e as TaskNestError {
                switch e {
                case .taskNotFound, .parentNotFound: failure = .error(.notFound, message: e.errorDescription ?? "not found")
                case .sameTask, .parentIsSubtask: failure = .error(.invalidParams, message: e.errorDescription ?? "invalid", data: ["field": "parentID"])
                }
            } catch {
                failure = .error(.internalError, message: "\(error)")
            }
        }
        if let failure { return failure }
        guard let final = store.task(t.id) else { return .error(.internalError, message: "task vanished during move") }
        struct Result: Encodable { let moved: Bool; let task: MCPTaskFull }
        return .ok(Result(moved: true, task: MCPTaskFull(final, today: today(), blocked: store.isBlocked(final.id))))
    }
}
#endif
