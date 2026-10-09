#if os(macOS)
// L4 — MCP. list_tasks and get_task. Split from MCPDispatcher+Tools.swift
// to keep every file under 500 lines.

import Foundation

extension MCPDispatcher {

    // MARK: - list_tasks

    func listTasks(_ arguments: Data) -> MCPToolOutcome {
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

    func applyView(_ view: MCPParams.ListTasks.View, to pool: [KTask],
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
    func cursorSignature(_ p: MCPParams.ListTasks) -> String {
        "\(p.view.rawValue)|\(p.projectID?.uuidString ?? "-")|\(p.labelID?.uuidString ?? "-")|" +
        "\(p.query ?? "-")|\(p.includeDone)|\(p.limit)|\(p.fields.rawValue)|" +
        "\(p.status?.rawValue ?? "-")|\(p.areaID?.uuidString ?? "-")|\(p.priority?.rawValue ?? "-")|" +
        "\(p.energyKind?.rawValue ?? "-")|\(p.due ?? "-")|\(p.dueFrom ?? "-")|\(p.dueTo ?? "-")|\(p.includeSubtasks)"
    }

    func encodeCursor(offset: Int, signature: String) -> String {
        let raw = "\(offset)|\(signature)"
        return Data(raw.utf8).base64EncodedString()
    }

    func decodeCursor(_ s: String) -> (offset: Int, signature: String)? {
        guard let data = Data(base64Encoded: s), let raw = String(data: data, encoding: .utf8) else { return nil }
        guard let bar = raw.firstIndex(of: "|") else { return nil }
        guard let offset = Int(raw[raw.startIndex..<bar]) else { return nil }
        let signature = String(raw[raw.index(after: bar)...])
        return (offset, signature)
    }

    // MARK: - get_task

    func getTask(_ arguments: Data) -> MCPToolOutcome {
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

}
#endif
