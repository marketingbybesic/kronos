#if os(macOS)
// L4 — MCP. create_task plus its attach/resolveProject helpers. Split
// from MCPDispatcher+Tools.swift to keep every file under 500 lines.

import Foundation

extension MCPDispatcher {

    // MARK: - create_task

    func createTask(_ arguments: Data) -> MCPToolOutcome {
        let params: MCPParams.CreateTask
        do { params = try decodeParams(MCPParams.CreateTask.self, arguments, tool: "create_task") } catch { return MCPToolOutcome.from(error) }
        let extras: MCPParams.CreateExtras
        do { extras = try decodeParams(MCPParams.CreateExtras.self, arguments, tool: "create_task") } catch { return MCPToolOutcome.from(error) }
        let cleaned = cleanContext(extras.context)
        if let p = cleaned.problem { return .error(.invalidParams, message: p, data: ["field": "context"]) }
        if let a = extras.assignee, !["me", "self"].contains(a) {
            return .error(.invalidParams, message: "assignee must be me or self", data: ["field": "assignee"])
        }
        if extras.assignee == "self", identity == nil {
            return .error(.invalidParams, message: "assignee self needs an agent identity", data: ["field": "assignee"])
        }
        if let tooLong = lengthError(title: params.title, notes: params.notes) { return tooLong }
        for step in params.subtasks ?? [] {
            if let tooLong = lengthError(title: step) { return tooLong }
        }
        if let ext = params.externalID,
           ext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ext.count > MCPLimits.maxExternalIDCharacters {
            return .error(.invalidParams,
                          message: "externalID must be 1-\(MCPLimits.maxExternalIDCharacters) characters",
                          data: ["field": "externalID"])
        }
        if let bad = linkError(params.links) { return bad }
        var plannedDay: Int?
        if let raw = params.plannedDay {
            let parsed = parseDay(raw, field: "plannedDay")
            if let e = parsed.error { return e }
            plannedDay = parsed.day
        }
        struct Result: Encodable {
            let created: Bool
            let task: MCPTaskFull
            let protectedFields: [String]
        }
        // A retry with the same externalID from the same agent is answered with the task the
        // first call made; nothing is written.
        if let ext = params.externalID,
           let existing = store.allTasksIncludingSubtasks().first(where: { $0.externalID == ext && $0.source == sourceTag }) {
            return .ok(Result(created: false,
                              task: MCPTaskFull(existing, today: today(), blocked: store.isBlocked(existing.id)),
                              protectedFields: []))
        }
        // `text` is natural quick-add syntax for ONE task, read by the same grammar as the app's
        // entry field. Every explicit field below wins over what the text says.
        var planned: EntryPlannedTask?
        if let text = params.text {
            let plans = EntryText.plan(text, directory: store.entryDirectory(), today: today())
            if plans.count > 1 {
                return .error(.invalidParams, message: "text describes \(plans.count) tasks; create_task creates one")
            }
            planned = plans.first
            if planned == nil && params.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .error(.invalidParams, message: "text has no title")
            }
        }
        let explicitTitle = params.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTitle = explicitTitle.isEmpty ? (planned?.title ?? "") : explicitTitle
        guard !trimmedTitle.isEmpty else {
            return .error(.invalidParams, message: "title must not be empty")
        }
        // A title read out of `text` is held to the same limit as an explicit one.
        if let tooLong = lengthError(title: trimmedTitle) { return tooLong }
        for step in planned?.subtasks ?? [] {
            if let tooLong = lengthError(title: step) { return tooLong }
        }
        // Fields that came from the text count as explicit: triage must not overwrite them.
        var textFields: Set<String> = []

        var project: KProject?
        var textAreaID: UUID?
        if let name = params.project {
            guard let found = resolveProject(name) else {
                return .error(.notFound, message: "no project matching \(name)", data: ["value": name])
            }
            project = found
        } else if let dest = planned?.resolved.destination {
            switch dest.kind {
            case .project: project = dest.id.flatMap { id in store.allProjects().first { $0.id == id } }
            case .area: textAreaID = dest.id
            }
            if project != nil || textAreaID != nil { textFields.insert("project") }
        }

        let effectiveLabels: [String]? = params.labels ?? planned?.resolved.labelName.map { [$0] }
        if params.labels == nil, effectiveLabels != nil { textFields.insert("labels") }
        if params.strictLabels, let names = effectiveLabels {
            let missing = unknownLabels(in: names)
            if !missing.isEmpty { return unknownLabelsError(missing) }
        }

        var due = params.due.flatMap(Day.parseISO)
        if params.due != nil && due == nil {
            return .error(.invalidParams, message: "due is not a valid date: \(params.due ?? "")")
        }
        if params.due == nil, let d = planned?.resolved.dueDay {
            due = d
            textFields.insert("due")
        }
        var priority: KPriority = params.priority?.kPriority ?? .none
        if params.priority == nil, let p = planned?.resolved.priority, p != .none {
            priority = p
            textFields.insert("priority")
        }
        if let est = params.estimateMinutes, est < 1 || est > 480 {
            return .error(.invalidParams, message: "estimateMinutes out of range")
        }

        let scopedDefaults = ListScopeDefaults.apply(scope: nil, explicitDueDay: due, today: today())
        let t = store.createNoUndo(title: trimmedTitle, notes: params.notes ?? "",
                                   project: project, status: scopedDefaults.status,
                                   priority: priority,
                                   dueDay: scopedDefaults.dueDay)
        store.updateNoUndo(t.id) { task in
            if let fm = params.firstMove { task.firstMove = fm }
            if let d = params.depth { task.depth = d.kDepth }
            if let est = params.estimateMinutes { task.estimateMinutes = est }
            task.needsTriage = params.triage
            task.source = self.sourceTag
            task.externalID = params.externalID
            if let areaID = textAreaID { task.areaID = areaID }
            if let day = plannedDay { task.plannedDay = day }
            if let dread = params.dread { task.dread = dread }
            if let kind = params.energyKind { task.energyKind = kind.kEnergyKind }
            if let links = params.links { self.attach(links, to: task) }
        }
        if let effort = params.effort?.kEffort ?? planned?.resolved.effort { store.setEffortNoUndo(t.id, effort) }
        for name in effectiveLabels ?? [] {
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
        for title in (params.subtasks ?? []) + (planned?.subtasks ?? []) {
            store.addSubtaskNoUndo(t.id, title: title)
        }

        var ctx = cleaned.context
        if ctx != nil { ctx?.kind = "task" }
        stampAgentTask(t.id, context: ctx, pending: nil, assignedToAgent: extras.assignee == "self")

        // Anything the caller set (or the text carried) is a decision triage must never overwrite;
        // with triage:false nothing may be filled at all.
        let explicit = params.protectedFields.union(textFields)
        let toLock: Set<TriageFieldKind> = params.triage
            ? Set(explicit.compactMap(Self.triageField))
            : Set(TriageFieldKind.allCases)
        for field in toLock { store.lockField(field, on: t.id) }

        guard let final = store.task(t.id) else {
            return .error(.internalError, message: "task vanished immediately after creation")
        }
        return .ok(Result(created: true, task: MCPTaskFull(final, today: today(), blocked: store.isBlocked(final.id)),
                          protectedFields: Array(params.protectedFields.union(textFields)).sorted()))
    }

    /// Attaches each link the task does not have yet. Never removes an attachment.
    func attach(_ links: [String], to task: KTask) {
        var current = task.attachments ?? []
        var have = Set(current.compactMap(\.url))
        for url in links where have.insert(url).inserted {
            current.append(KAttachment(kindRaw: 0, title: url, url: url))
        }
        task.attachments = current
    }

    /// Exact match, then case-insensitive prefix, then substring.
    /// `project` may also be a UUID string.
    func resolveProject(_ nameOrID: String) -> KProject? {
        if let id = UUID(uuidString: nameOrID) {
            return store.allProjects().first { $0.id == id }
        }
        let folded = KTextFold.fold(nameOrID)
        let all = store.allProjects()
        if let exact = all.first(where: { KTextFold.fold($0.name) == folded }) { return exact }
        if let prefix = all.first(where: { KTextFold.fold($0.name).hasPrefix(folded) }) { return prefix }
        return all.first { KTextFold.fold($0.name).contains(folded) }
    }

}
#endif
