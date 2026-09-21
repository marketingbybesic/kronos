// L4 — MCP. The 13 tool implementations. Split from MCPDispatcher.swift to
// keep every file under 500 lines. Each tool decodes its frozen
// Contracts/MCPParams struct, calls TaskStoring (NoUndo for every mutator),
// and returns an MCPToolOutcome.

import Foundation

extension MCPDispatcher {

    func dispatch(_ tool: MCPTool, arguments: Data) -> MCPToolOutcome {
        switch tool {
        case .listTasks:     return listTasks(arguments)
        case .getTask:       return getTask(arguments)
        case .createTask:    return createTask(arguments)
        case .updateTask:    return updateTask(arguments)
        case .completeTask:  return completeTask(arguments)
        case .deleteTask:    return deleteTask(arguments)
        case .restoreTask:   return restoreTask(arguments)
        case .addSubtask:    return addSubtask(arguments)
        case .toggleSubtask: return toggleSubtask(arguments)
        case .ordoGet:       return ordoGet(arguments)
        case .ordoSet:       return ordoSet(arguments)
        case .rulesList:     return rulesList(arguments)
        case .rulesAdd:      return rulesAdd(arguments)
        }
    }

    // MARK: - list_tasks

    private func listTasks(_ arguments: Data) -> MCPToolOutcome {
        guard let params = try? MCPJSON.decoder.decode(MCPParams.ListTasks.self, from: arguments) else {
            return .error(.invalidParams, message: "could not decode list_tasks arguments")
        }
        if let v = params.validationError {
            return .error(v, message: "invalid list_tasks arguments for view \(params.view.rawValue)")
        }

        let day = today()
        var pool = store.allTasks()
        pool = applyView(params.view, to: pool, params: params, today: day)
        if !params.includeDone {
            pool = pool.filter { KStatus.closed.contains($0.status) == false }
        }
        if params.view == .search, let q = params.query {
            let needle = KTextFold.fold(q)
            pool = pool.filter { KTextFold.fold($0.title).contains(needle) || KTextFold.fold($0.notes).contains(needle) }
        }
        if let labelID = params.labelID {
            pool = pool.filter { (($0.labels ?? []).map(\.id)).contains(labelID) }
        }

        let ordered = params.view == .ordo
            ? pool.sorted(by: Ordering.ordo)
            : KTaskSorter.sorted(pool, by: [.asc(.manual)])
        let total = ordered.count

        let signature = cursorSignature(params)
        let offset: Int
        if let cursor = params.cursor {
            guard let decoded = decodeCursor(cursor), decoded.signature == signature else {
                return .error(.invalidCursor, message: "cursor does not match this query")
            }
            offset = decoded.offset
        } else {
            offset = 0
        }
        guard offset >= 0, offset <= total else {
            return .error(.invalidCursor, message: "cursor out of range")
        }

        let page = Array(ordered[offset..<min(offset + params.limit, total)])
        let hasMore = offset + page.count < total
        let nextCursor = hasMore ? encodeCursor(offset: offset + page.count, signature: signature) : nil

        let tasks: [AnyEncodable] = page.map { t in
            params.fields == .full
                ? AnyEncodable(jsonObject(MCPTaskFull(t, today: day)))
                : AnyEncodable(jsonObject(MCPTaskCompact(t)))
        }

        // Built in typed steps: as one chained expression this exceeded the type-checker budget.
        let projectRefs: [MCPProjectRef] = store.allProjects().map { (p: KProject) -> MCPProjectRef in
            MCPProjectRef(id: p.id, name: p.name, areaName: p.area?.name, icon: p.icon)
        }
        let allLabels: [KLabel] = pool.flatMap { (t: KTask) -> [KLabel] in t.labels ?? [] }
        var seenLabelIDs = Set<UUID>()
        let uniqueLabels: [KLabel] = allLabels.filter { seenLabelIDs.insert($0.id).inserted }
        let labelRefs: [MCPLabelRef] = uniqueLabels
            .map { (l: KLabel) -> MCPLabelRef in MCPLabelRef(id: l.id, name: l.name) }
            .sorted { (a: MCPLabelRef, b: MCPLabelRef) -> Bool in KTextFold.fold(a.name) < KTextFold.fold(b.name) }
        let meta = MCPListMeta(projects: projectRefs, labels: labelRefs)

        struct Result: Encodable {
            let tasks: [AnyEncodable]
            let total: Int
            let returned: Int
            let hasMore: Bool
            let nextCursor: String?
            let meta: MCPListMeta
        }
        return .ok(Result(tasks: tasks, total: total, returned: page.count,
                          hasMore: hasMore, nextCursor: nextCursor, meta: meta))
    }

    private func applyView(_ view: MCPParams.ListTasks.View, to pool: [KTask],
                           params: MCPParams.ListTasks, today: Int) -> [KTask] {
        switch view {
        case .inbox:
            return pool.filter { $0.projectID == nil && $0.status != .someday }
        case .today:
            return pool.filter { t in
                guard t.status != .someday else { return false }
                let dueToday = t.dueDay.map { $0 <= today } ?? false
                return dueToday || t.isInOrdo
            }
        case .upcoming:
            return pool.filter { t in
                guard let d = t.dueDay, t.status != .someday else { return false }
                return d > today && d <= today + 7
            }
        case .anytime:
            return pool.filter { $0.dueDay == nil && $0.status != .someday }
        case .someday:
            return pool.filter { $0.status == .someday }
        case .project:
            guard let pid = params.projectID else { return [] }
            return pool.filter { $0.projectID == pid }
        case .label:
            // labelID filter is applied uniformly after this switch.
            return pool
        case .ordo:
            return pool.filter { $0.isInOrdo }
        case .search:
            return pool
        }
    }

    /// A short signature over every filter argument except the cursor
    /// itself, so replaying a cursor against a different query is rejected
    /// rather than silently paginating through the wrong result set.
    private func cursorSignature(_ p: MCPParams.ListTasks) -> String {
        "\(p.view.rawValue)|\(p.projectID?.uuidString ?? "-")|\(p.labelID?.uuidString ?? "-")|" +
        "\(p.query ?? "-")|\(p.includeDone)|\(p.limit)|\(p.fields.rawValue)"
    }

    private func encodeCursor(offset: Int, signature: String) -> String {
        let raw = "\(offset)|\(signature)"
        return Data(raw.utf8).base64EncodedString()
    }

    private func decodeCursor(_ s: String) -> (offset: Int, signature: String)? {
        guard let data = Data(base64Encoded: s), let raw = String(data: data, encoding: .utf8) else { return nil }
        guard let bar = raw.firstIndex(of: "|") else { return nil }
        guard let offset = Int(raw[raw.startIndex..<bar]) else { return nil }
        let signature = String(raw[raw.index(after: bar)...])
        return (offset, signature)
    }

    // MARK: - get_task

    private func getTask(_ arguments: Data) -> MCPToolOutcome {
        guard let params = try? MCPJSON.decoder.decode(MCPParams.TaskID.self, from: arguments) else {
            return .error(.invalidParams, message: "could not decode get_task arguments")
        }
        guard let t = store.task(params.id) else {
            return .error(.notFound, message: "no task \(params.id)")
        }
        struct Result: Encodable {
            let task: MCPTaskFull
            let subtasks: [MCPSubtaskDTO]
        }
        return .ok(Result(task: MCPTaskFull(t, today: today()),
                          subtasks: t.orderedSubtasks.map { MCPSubtaskDTO($0, taskID: t.id) }))
    }

    // MARK: - create_task

    private func createTask(_ arguments: Data) -> MCPToolOutcome {
        guard let params = try? MCPJSON.decoder.decode(MCPParams.CreateTask.self, from: arguments) else {
            return .error(.invalidParams, message: "could not decode create_task arguments")
        }
        let trimmedTitle = params.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            return .error(.invalidParams, message: "title must not be empty")
        }

        var project: KProject?
        if let name = params.project {
            guard let found = resolveProject(name) else {
                return .error(.notFound, message: "no project matching \(name)", data: ["value": name])
            }
            project = found
        }

        let due = params.due.flatMap(Day.parseISO)
        if params.due != nil && due == nil {
            return .error(.invalidParams, message: "due is not a valid date: \(params.due ?? "")")
        }
        if let est = params.estimateMinutes, est < 1 || est > 480 {
            return .error(.invalidParams, message: "estimateMinutes out of range")
        }

        // Status comes from the SAME shared default quick add/Capture use
        // (ListScopeDefaults.apply), not a hardcoded .todo, so an MCP-created task with no due
        // date follows the same "no date -> Someday" rule as every other creation path.
        // create_task has no scope concept of its own (no "put this in Someday" param), so
        // `scope: nil` is the only correct argument here — this call site routes through the
        // shared function so any future change to that default rule needs no edit here.
        let scopedDefaults = ListScopeDefaults.apply(scope: nil, explicitDueDay: due, today: today())
        let t = store.createNoUndo(title: trimmedTitle, notes: params.notes ?? "",
                                   project: project, status: scopedDefaults.status,
                                   priority: params.priority?.kPriority ?? .none,
                                   dueDay: scopedDefaults.dueDay)
        store.updateNoUndo(t.id) { task in
            if let fm = params.firstMove { task.firstMove = fm }
            if let d = params.depth { task.depth = d.kDepth }
            if let est = params.estimateMinutes { task.estimateMinutes = est }
            task.needsTriage = params.triage
        }
        for name in params.labels ?? [] {
            // `label(named:)` registers its own undo step when it creates a
            // new label. Doing the lookup INSIDE the updateNoUndo closure
            // keeps that step inside the same withoutUndo window the
            // mutation runs in, so it is discarded along with everything
            // else the write touched (TaskStore+NoUndo.swift's withoutUndo).
            store.updateNoUndo(t.id) { task in
                // Raw name, matching every other caller of label(named:)
                // (JSONExporterTests, FilterTests) — it does its own
                // mergeKey lookup internally.
                let label = self.store.label(named: name)
                var current = task.labels ?? []
                if !current.contains(where: { $0.id == label.id }) { current.append(label) }
                task.labels = current
            }
        }
        for title in params.subtasks ?? [] {
            store.addSubtaskNoUndo(t.id, title: title)
        }

        guard let final = store.task(t.id) else {
            return .error(.internalError, message: "task vanished immediately after creation")
        }
        struct Result: Encodable {
            let created: Bool
            let task: MCPTaskFull
            let protectedFields: [String]
        }
        return .ok(Result(created: true, task: MCPTaskFull(final, today: today()),
                          protectedFields: Array(params.protectedFields).sorted()))
    }

    /// Exact match, then case-insensitive prefix, then substring.
    /// `project` may also be a UUID string.
    private func resolveProject(_ nameOrID: String) -> KProject? {
        if let id = UUID(uuidString: nameOrID) {
            return store.allProjects().first { $0.id == id }
        }
        let folded = KTextFold.fold(nameOrID)
        let all = store.allProjects()
        if let exact = all.first(where: { KTextFold.fold($0.name) == folded }) { return exact }
        if let prefix = all.first(where: { KTextFold.fold($0.name).hasPrefix(folded) }) { return prefix }
        return all.first { KTextFold.fold($0.name).contains(folded) }
    }

    // MARK: - update_task

    private func updateTask(_ arguments: Data) -> MCPToolOutcome {
        guard let params = try? MCPJSON.decoder.decode(MCPParams.UpdateTask.self, from: arguments) else {
            return .error(.invalidParams, message: "could not decode update_task arguments")
        }
        guard store.task(params.id) != nil else {
            return .error(.notFound, message: "no task \(params.id)")
        }
        if let title = params.title, title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .error(.invalidParams, message: "title must not be empty")
        }

        var resolvedProject: KProject??
        if case .some(let projectPatch) = params.project {
            if let name = projectPatch {
                guard let found = resolveProject(name) else {
                    return .error(.notFound, message: "no project matching \(name)", data: ["value": name])
                }
                resolvedProject = .some(found)
            } else {
                resolvedProject = .some(nil)
            }
        }

        var resolvedDue: Int??
        if case .some(let duePatch) = params.due {
            if let s = duePatch {
                guard let parsed = Day.parseISO(s) else {
                    return .error(.invalidParams, message: "due is not a valid date: \(s)")
                }
                resolvedDue = .some(parsed)
            } else {
                resolvedDue = .some(nil)
            }
        }

        var sideEffects: [String] = []

        // status:"done" behaves exactly like complete_task.
        if params.status == .done {
            store.completeNoUndo(params.id)
            sideEffects.append("completed")
        } else if let status = params.status {
            store.setStatusNoUndo(params.id, status.kStatus)
            if status == .waiting || status == .someday { sideEffects.append("ordoIndexCleared") }
        }

        store.updateNoUndo(params.id) { t in
            if let title = params.title { t.title = title }
            if let notes = params.notes { t.notes = notes }
            if let fm = params.firstMove { t.firstMove = fm }
            if let p = resolvedProject {
                t.project = p
                t.projectID = p?.id
                t.areaID = p?.area?.id
                t.isProjectArchived = p?.isArchived ?? false
            }
            if let priority = params.priority { t.priority = priority.kPriority }
            if let due = resolvedDue { t.dueDay = due; if t.originalDueDay == nil { t.originalDueDay = due } }
            if let labels = params.labels {
                t.labels = labels.map { self.store.label(named: $0) }
            }
            if let depth = params.depth { t.depth = depth.kDepth }
            if let est = params.estimateMinutes { t.estimateMinutes = est }
        }

        guard let final = store.task(params.id) else {
            return .error(.internalError, message: "task vanished during update")
        }
        struct Result: Encodable {
            let updated: Bool
            let task: MCPTaskFull
            let sideEffects: [String]
        }
        return .ok(Result(updated: true, task: MCPTaskFull(final, today: today()), sideEffects: sideEffects))
    }

    // MARK: - complete_task

    private func completeTask(_ arguments: Data) -> MCPToolOutcome {
        guard let params = try? MCPJSON.decoder.decode(MCPParams.TaskID.self, from: arguments) else {
            return .error(.invalidParams, message: "could not decode complete_task arguments")
        }
        guard let t = store.task(params.id) else {
            return .error(.notFound, message: "no task \(params.id)")
        }
        if t.status == .done || t.status == .canceled {
            return .error(.invalidState, message: "task is already \(t.status == .done ? "done" : "canceled")",
                          data: ["status": t.status == .done ? "done" : "canceled"])
        }
        store.completeNoUndo(params.id)
        guard let final = store.task(params.id) else {
            return .error(.internalError, message: "task vanished during completion")
        }
        struct Result: Encodable {
            let completed: Bool
            let task: MCPTaskFull
            let openSubtasksLeft: Int
        }
        let openLeft = (final.subtasks ?? []).filter { !$0.isDone }.count
        return .ok(Result(completed: true, task: MCPTaskFull(final, today: today()), openSubtasksLeft: openLeft))
    }

    // MARK: - delete_task / restore_task

    private func deleteTask(_ arguments: Data) -> MCPToolOutcome {
        guard let params = try? MCPJSON.decoder.decode(MCPParams.DeleteTask.self, from: arguments) else {
            return .error(.invalidParams, message: "could not decode delete_task arguments")
        }
        if let v = params.validationError {
            return .error(v, message: "confirm must be true")
        }
        guard store.task(params.id) != nil else {
            return .error(.notFound, message: "no task \(params.id)")
        }
        store.softDeleteNoUndo(params.id)
        struct Result: Encodable { let deleted: Bool; let id: UUID }
        return .ok(Result(deleted: true, id: params.id))
    }

    private func restoreTask(_ arguments: Data) -> MCPToolOutcome {
        guard let params = try? MCPJSON.decoder.decode(MCPParams.TaskID.self, from: arguments) else {
            return .error(.invalidParams, message: "could not decode restore_task arguments")
        }
        guard store.taskIncludingDeleted(params.id) != nil else {
            return .error(.notFound, message: "no task \(params.id), even including deleted")
        }
        store.restoreNoUndo(params.id)
        struct Result: Encodable { let restored: Bool; let id: UUID }
        return .ok(Result(restored: true, id: params.id))
    }

}

/// Encodes any Encodable value to a JSONSerialization-compatible object, for
/// embedding inside the loosely-typed `tasks: [AnyEncodable]` array.
func jsonObject<T: Encodable>(_ value: T) -> Any {
    guard let data = try? MCPJSON.encoder.encode(value) else { return [String: Any]() }
    return (try? JSONSerialization.jsonObject(with: data)) ?? [String: Any]()
}
