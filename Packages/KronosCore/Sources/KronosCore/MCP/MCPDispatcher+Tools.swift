#if os(macOS)
// L4 — MCP. The 13 tool implementations. Split from MCPDispatcher.swift to
// keep every file under 500 lines. Each tool decodes its frozen
// Contracts/MCPParams struct, calls TaskStoring (NoUndo for every mutator),
// and returns an MCPToolOutcome.

import Foundation

extension MCPDispatcher {

    func dispatch(_ tool: MCPTool, arguments: Data) -> MCPToolOutcome {
        // An alias runs its target's handler, so both names always answer the same.
        switch tool.canonical {
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
        case .rulesDelete:   return rulesDelete(arguments)
        case .whoami:        return whoami(arguments)
        case .proposeTasks:  return proposeTasks(arguments)
        case .proposeUpdate: return proposeUpdate(arguments)
        case .commentTask:   return commentTask(arguments)
        case .eventsPoll:    return eventsPoll(arguments)
        case .eventsAck:     return eventsAck(arguments)
        case .next:          return next(arguments)
        case .upnextGet, .upnextSet:
            return .error(.internalError, message: "alias \(tool.name) was not resolved")
        case .listProjects:  return listProjects(arguments)
        case .listAreas:     return listAreas(arguments)
        }
    }

    // MARK: - list_tasks

    private func listTasks(_ arguments: Data) -> MCPToolOutcome {
        let params: MCPParams.ListTasks
        do { params = try decodeParams(MCPParams.ListTasks.self, arguments, tool: "list_tasks") } catch { return MCPToolOutcome.from(error) }
        if let v = params.validationError {
            return .error(v, message: "invalid list_tasks arguments for view \(params.view.rawValue)")
        }

        // Validate filter inputs against the store so a typo is an error, not an empty list.
        if let pid = params.projectID,
           !store.allProjects(includeArchived: true).contains(where: { $0.id == pid }) {
            return .error(.notFound, message: "no project \(pid)", data: ["projectID": pid.uuidString])
        }
        if let aid = params.areaID, !store.allAreas().contains(where: { $0.id == aid }) {
            return .error(.notFound, message: "no area \(aid)", data: ["areaID": aid.uuidString])
        }
        var dueExact: Int?, dueFrom: Int?, dueTo: Int?
        for (name, raw) in [("due", params.due), ("dueFrom", params.dueFrom), ("dueTo", params.dueTo)] {
            guard let raw else { continue }
            guard let parsed = Day.parseISO(raw) else {
                return .error(.invalidParams, message: "\(name) is not a valid date (yyyy-MM-dd): \(raw)")
            }
            switch name {
            case "due": dueExact = parsed
            case "dueFrom": dueFrom = parsed
            default: dueTo = parsed
            }
        }

        let extras: MCPParams.ListExtras
        do { extras = try decodeParams(MCPParams.ListExtras.self, arguments, tool: "list_tasks") } catch { return MCPToolOutcome.from(error) }
        var updatedSince: Date?, completedSince: Date?
        for (name, raw) in [("updatedSince", extras.updatedSince), ("completedSince", extras.completedSince)] {
            guard let raw else { continue }
            guard let d = Self.parseTimestamp(raw) else {
                return .error(.invalidParams, message: "\(name) is not an ISO-8601 time: \(raw)", data: ["field": name])
            }
            if name == "updatedSince" { updatedSince = d } else { completedSince = d }
        }
        if let r = extras.review, Self.reviewRaw(named: r) == nil {
            return .error(.invalidParams, message: "review must be pending, approved, rejected or awaitingCheck", data: ["field": "review"])
        }
        if let o = extras.owner, !["me", "agent", "any"].contains(o), hub?.agent(slug: o) == nil {
            return .error(.notFound, message: "no agent \(o)", data: ["field": "owner"])
        }

        let day = today()
        // Subtasks are listed only on request; they are otherwise reached through their parent.
        var pool = params.includeSubtasks ? store.allTasksIncludingSubtasks() : store.allTasks()
        pool = applyView(params.view, to: pool, params: params, today: day)
        if let status = params.status {
            pool = pool.filter { $0.status == status.kStatus }
        } else if !params.includeDone && completedSince == nil {
            pool = pool.filter { KStatus.closed.contains($0.status) == false }
        }
        if let aid = params.areaID {
            pool = pool.filter { $0.areaID == aid || $0.project?.area?.id == aid }
        }
        if let p = params.priority { pool = pool.filter { $0.priority == p.kPriority } }
        if let e = params.energyKind { pool = pool.filter { $0.energyKind == e.kEnergyKind } }
        // Dates read the effective due day (own day or an earlier open subtask's), the same
        // rule the app's Today / Next 7 / overdue lists use.
        if let d = dueExact { pool = pool.filter { $0.effectiveDue == d } }
        if let from = dueFrom { pool = pool.filter { ($0.effectiveDue ?? Int.min) >= from } }
        if let to = dueTo { pool = pool.filter { $0.effectiveDue.map { $0 <= to } ?? false } }
        if params.view == .search, let q = params.query {
            let needle = KTextFold.fold(q)
            pool = pool.filter { $0.titleOrSubtaskTitleContains(needle) || KTextFold.fold($0.notes).contains(needle) }
        }
        if let labelID = params.labelID {
            pool = pool.filter { (($0.labels ?? []).map(\.id)).contains(labelID) }
        }
        if let since = updatedSince { pool = pool.filter { $0.updatedAt >= since } }
        if let since = completedSince { pool = pool.filter { $0.completedAt.map { $0 >= since } ?? false } }
        if let r = extras.review, let raw = Self.reviewRaw(named: r) { pool = pool.filter { $0.reviewRaw == raw } }
        if let o = extras.owner {
            switch o {
            case "me": pool = pool.filter { $0.agentID == nil }
            case "agent": pool = pool.filter { $0.agentID != nil }
            case "any": break
            default:
                let id = hub?.agent(slug: o)?.id
                pool = pool.filter { $0.agentID == id }
            }
        }

        let ordered = params.view == .ordo
            ? pool.sorted(by: Ordering.ordo)
            : KTaskSorter.sorted(pool, by: [.asc(.manual)])
        let total = ordered.count

        let signature = cursorSignature(params) + "|\(extras.updatedSince ?? "-")|\(extras.completedSince ?? "-")|\(extras.owner ?? "-")|\(extras.review ?? "-")"
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

        let blockedIDs = store.blockedIDs(in: page)
        let tasks: [AnyEncodable] = page.map { t in
            params.fields == .full
                ? AnyEncodable(jsonObject(MCPTaskFull(t, today: day, blocked: blockedIDs.contains(t.id))))
                : AnyEncodable(jsonObject(MCPTaskCompact(t, blocked: blockedIDs.contains(t.id))))
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
        let areaRefs: [MCPAreaRef] = store.allAreas().map { (a: KArea) -> MCPAreaRef in MCPAreaRef(id: a.id, name: a.name) }
        let meta = MCPListMeta(areas: areaRefs, projects: projectRefs, labels: labelRefs)

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
                let dueToday = t.effectiveDue.map { $0 <= today } ?? false
                let plannedToday = t.plannedDay.map { $0 <= today } ?? false
                return dueToday || plannedToday || t.isInOrdo
            }
        case .upcoming:
            return pool.filter { t in
                guard let d = t.effectiveDue, t.status != .someday else { return false }
                return d > today && d <= today + 7
            }
        case .anytime:
            return pool.filter { $0.effectiveDue == nil && $0.status != .someday }
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
        case .search, .all:
            return pool
        }
    }

    /// A short signature over every filter argument except the cursor
    /// itself, so replaying a cursor against a different query is rejected
    /// rather than silently paginating through the wrong result set.
    private func cursorSignature(_ p: MCPParams.ListTasks) -> String {
        "\(p.view.rawValue)|\(p.projectID?.uuidString ?? "-")|\(p.labelID?.uuidString ?? "-")|" +
        "\(p.query ?? "-")|\(p.includeDone)|\(p.limit)|\(p.fields.rawValue)|" +
        "\(p.status?.rawValue ?? "-")|\(p.areaID?.uuidString ?? "-")|\(p.priority?.rawValue ?? "-")|" +
        "\(p.energyKind?.rawValue ?? "-")|\(p.due ?? "-")|\(p.dueFrom ?? "-")|\(p.dueTo ?? "-")|\(p.includeSubtasks)"
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
        let params: MCPParams.TaskID
        do { params = try decodeParams(MCPParams.TaskID.self, arguments, tool: "get_task") } catch { return MCPToolOutcome.from(error) }
        guard let t = store.task(params.id) else {
            return .error(.notFound, message: "no task \(params.id)")
        }
        // `children`: every subtask as a full task object (each one works with every task
        // tool by its id). `subtasks`: the same rows in the older compact step shape.
        struct Result: Encodable {
            let task: MCPTaskFull
            let children: [MCPTaskFull]
            let subtasks: [MCPSubtaskDTO]
        }
        let kids = t.orderedChildren
        return .ok(Result(task: MCPTaskFull(t, today: today(), blocked: store.isBlocked(t.id)),
                          children: kids.map { MCPTaskFull($0, today: today(), blocked: store.isBlocked($0.id)) },
                          subtasks: kids.map { MCPSubtaskDTO($0, taskID: t.id) }))
    }

    // MARK: - create_task

    private func createTask(_ arguments: Data) -> MCPToolOutcome {
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

    // MARK: - update_task

    private func updateTask(_ arguments: Data) -> MCPToolOutcome {
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

    // MARK: - complete_task

    private func completeTask(_ arguments: Data) -> MCPToolOutcome {
        let params: MCPParams.TaskID
        do { params = try decodeParams(MCPParams.TaskID.self, arguments, tool: "complete_task") } catch { return MCPToolOutcome.from(error) }
        guard let t = store.task(params.id) else {
            return .error(.notFound, message: "no task \(params.id)")
        }
        if t.status == .done || t.status == .canceled {
            return .error(.invalidState, message: "task is already \(t.status == .done ? "done" : "canceled")",
                          data: ["status": t.status == .done ? "done" : "canceled"])
        }
        let extras: MCPParams.CompleteExtras
        do { extras = try decodeParams(MCPParams.CompleteExtras.self, arguments, tool: "complete_task") } catch { return MCPToolOutcome.from(error) }
        if let note = extras.result?.note, note.count > 280 {
            return .error(.invalidParams, message: "result.note is \(note.count) characters; the limit is 280", data: ["field": "result.note"])
        }
        if let bad = linkError(extras.result?.links?.map(\.url)) { return bad }
        // A task handed to an agent is not closed by the agent: it goes back to the person to check.
        if let me = identity, t.assigneeRaw == 1, t.agentID == me.agentID {
            var result = AgentTaskResult()
            result.outcome = "done"
            result.by = me.actor
            result.note = extras.result?.note
            result.links = extras.result?.links
            result.completedAt = Date()
            store.updateNoUndo(params.id) { $0.reviewRaw = ReviewState.awaitingCheck; $0.resultJSON = result.encoded() }
            hub?.append(actor: me.actor, verb: ActivityVerb.doneByAgent, taskID: params.id, agentID: me.agentID,
                        payload: ["title": .string(t.title)])
            guard let waiting = store.task(params.id) else { return .error(.internalError, message: "task vanished") }
            struct Waiting: Encodable { let completed: Bool; let review: String; let task: MCPTaskFull }
            return .ok(Waiting(completed: false, review: "awaitingCheck",
                               task: MCPTaskFull(waiting, today: today(), blocked: store.isBlocked(waiting.id))))
        }
        if let result = extras.result, identity == nil || t.agentID == identity?.agentID {
            var r = AgentTaskResult()
            r.outcome = "done"; r.by = identity?.actor ?? "me"; r.note = result.note; r.links = result.links
            store.updateNoUndo(params.id) { $0.resultJSON = r.encoded() }
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
        let openLeft = final.orderedChildren.filter { KStatus.open.contains($0.status) }.count
        return .ok(Result(completed: true, task: MCPTaskFull(final, today: today(), blocked: store.isBlocked(final.id)), openSubtasksLeft: openLeft))
    }

    // MARK: - delete_task / restore_task

    private func deleteTask(_ arguments: Data) -> MCPToolOutcome {
        let params: MCPParams.DeleteTask
        do { params = try decodeParams(MCPParams.DeleteTask.self, arguments, tool: "delete_task") } catch { return MCPToolOutcome.from(error) }
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
        let params: MCPParams.TaskID
        do { params = try decodeParams(MCPParams.TaskID.self, arguments, tool: "restore_task") } catch { return MCPToolOutcome.from(error) }
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
#endif
