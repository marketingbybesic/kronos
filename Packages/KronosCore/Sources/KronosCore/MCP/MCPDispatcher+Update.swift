#if os(macOS)
// L4 — MCP. update_task. Split from MCPDispatcher+Tools.swift to keep
// every file under 500 lines.

import Foundation

extension MCPDispatcher {

    // MARK: - update_task

    func updateTask(_ arguments: Data) -> MCPToolOutcome {
        let params: MCPParams.UpdateTask
        do { params = try decodeParams(MCPParams.UpdateTask.self, arguments, tool: "update_task") } catch { return MCPToolOutcome.from(error) }
        guard let existing = store.task(params.id) else {
            return .error(.notFound, message: "no task \(params.id)")
        }
        if let tooLong = lengthError(title: params.title, notes: params.notes) { return tooLong }
        if let append = params.notesAppend {
            let base = params.notes ?? existing.notes
            let combined = base.isEmpty ? append : base + "\n" + append
            if let tooLong = lengthError(notes: combined) { return tooLong }
        }
        if let bad = linkError(params.links) { return bad }
        if let title = params.title, title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .error(.invalidParams, message: "title must not be empty")
        }

        if params.strictLabels, let names = params.labels.map({ $0 + (params.labelsAdd ?? []) }) ?? params.labelsAdd {
            let missing = unknownLabels(in: names)
            if !missing.isEmpty { return unknownLabelsError(missing) }
        }

        var resolvedPlanned: Int??
        if case .some(let plannedPatch) = params.plannedDay {
            if let raw = plannedPatch {
                let parsed = parseDay(raw, field: "plannedDay")
                if let e = parsed.error { return e }
                resolvedPlanned = .some(parsed.day)
            } else {
                resolvedPlanned = .some(nil)
            }
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

        // A subtask carries its parent's project: filing it elsewhere makes it a standalone task
        // (the same rule as moving it in the app), instead of leaving a child in a foreign project.
        if let p = resolvedProject, let current = store.task(params.id), current.isSubtask,
           current.parent?.projectID != p?.id,
           (try? store.setParentNoUndo(params.id, to: nil, at: .afterFormerParent)) != nil {
            sideEffects.append("promotedToTask")
        }

        store.updateNoUndo(params.id) { t in
            if let title = params.title { t.title = title }
            if let notes = params.notes { t.notes = notes }
            if let append = params.notesAppend {
                t.notes = t.notes.isEmpty ? append : t.notes + "\n" + append
            }
            if let fm = params.firstMove { t.firstMove = fm }
            if let p = resolvedProject {
                t.project = p
                t.projectID = p?.id
                t.areaID = p?.area?.id
                t.isProjectArchived = p?.isArchived ?? false
            }
            if let priority = params.priority { t.priority = priority.kPriority }
            if let due = resolvedDue { t.dueDay = due; if t.originalDueDay == nil { t.originalDueDay = due } }
            if params.labels != nil || params.labelsAdd != nil || params.labelsRemove != nil {
                var labels: [KLabel] = params.labels.map { $0.map { self.store.label(named: $0) } } ?? (t.labels ?? [])
                for name in params.labelsAdd ?? [] {
                    let label = self.store.label(named: name)
                    if !labels.contains(where: { $0.id == label.id }) { labels.append(label) }
                }
                let dropped = Set((params.labelsRemove ?? []).map { KLabel(name: $0).mergeKey })
                t.labels = labels.filter { !dropped.contains($0.mergeKey) }
            }
            if let planned = resolvedPlanned { t.plannedDay = planned }
            if let dread = params.dread { t.dread = dread }
            if let kind = params.energyKind { t.energyKind = kind?.kEnergyKind }
            if let links = params.links { self.attach(links, to: t) }
            if let depth = params.depth { t.depth = depth.kDepth }
            if let est = params.estimateMinutes { t.estimateMinutes = est }
        }
        // A field the caller wrote explicitly (priority:"none" included) is locked against triage.
        var written: Set<TriageFieldKind> = []
        if params.priority != nil { written.insert(.priority) }
        if resolvedProject != nil { written.insert(.project) }
        if resolvedDue != nil { written.insert(.due) }
        if params.firstMove != nil { written.insert(.firstMove) }
        if params.labels != nil || params.labelsAdd != nil || params.labelsRemove != nil { written.insert(.labels) }
        if params.effort != nil { written.insert(.effort) }
        if params.energyKind != nil { written.insert(.energyKind) }
        if params.depth != nil { written.insert(.depth) }
        if params.estimateMinutes != nil { written.insert(.estimateMinutes) }
        if let effort = params.effort { store.setEffortNoUndo(params.id, effort.kEffort) }
        for field in written { store.lockField(field, on: params.id) }
        if let ids = params.waitsOn, !store.setWaitsOnNoUndo(params.id, ids) {
            sideEffects.append("waitsOnDropped")  // self, unknown, duplicate or cycle-closing ids
        }

        guard let final = store.task(params.id) else {
            return .error(.internalError, message: "task vanished during update")
        }
        struct Result: Encodable {
            let updated: Bool
            let task: MCPTaskFull
            let sideEffects: [String]
        }
        return .ok(Result(updated: true, task: MCPTaskFull(final, today: today(), blocked: store.isBlocked(final.id)), sideEffects: sideEffects))
    }

}
#endif
