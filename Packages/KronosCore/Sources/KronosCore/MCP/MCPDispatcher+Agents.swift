#if os(macOS)
// The agent loop: whoami, propose_tasks, propose_update, comment_task, events_poll, events_ack,
// next. Proposals are tasks with reviewRaw = 1: they exist in the store but are invisible to
// Today, Up next, Impuls and the menu bar until the person approves (see ReviewTransitions).

import Foundation

/// The list the app is showing, for `next`: its first ids in display order, the pinned task,
/// and the task the menu bar shows. Built by the app (UIContract.shownListHead).
public struct MCPNextCandidates: Equatable, Sendable {
    public var listName: String
    public var ids: [UUID]
    public var pinned: UUID?
    public var barTaskID: UUID?
    public init(listName: String, ids: [UUID], pinned: UUID? = nil, barTaskID: UUID? = nil) {
        self.listName = listName; self.ids = ids; self.pinned = pinned; self.barTaskID = barTaskID
    }
}

extension MCPDispatcher {

    // MARK: - Context handling

    /// A caller's context reduced to the fields an agent may set. Review bookkeeping
    /// (kind, proposal ids, update, comments) is never taken from the caller.
    func cleanContext(_ raw: AgentContext?) -> (context: AgentContext?, problem: String?) {
        guard var c = raw else { return (nil, nil) }
        if let p = c.validationProblem() { return (nil, p) }
        c.kind = nil; c.proposalID = nil; c.proposalTitle = nil; c.update = nil; c.comments = nil
        return (c, nil)
    }

    /// Marks a freshly created task as an agent's (and pending review unless trusted).
    func stampAgentTask(_ id: UUID, context: AgentContext?, pending: Bool?, assignedToAgent: Bool = false) {
        guard let me = identity else {
            if let context { store.updateNoUndo(id) { $0.contextJSON = context.encoded() } }
            return
        }
        let isPending = pending ?? !me.scopes.has(.writeTrusted)
        store.updateNoUndo(id) { t in
            t.agentID = me.agentID
            t.reviewRaw = isPending ? ReviewState.pending : ReviewState.none
            t.assigneeRaw = assignedToAgent ? 1 : 0
            if let context { t.contextJSON = context.encoded() }
        }
        hub?.append(actor: me.actor, verb: ActivityVerb.created, taskID: id, agentID: me.agentID, payload: [
            "title": .string(store.task(id)?.title ?? ""), "review": .number(Double(isPending ? 1 : 0)),
        ])
    }

    // MARK: - whoami

    func whoami(_ arguments: Data) -> MCPToolOutcome {
        struct Agent: Encodable { let slug: String; let displayName: String }
        struct Result: Encodable {
            let agent: Agent?
            let scopes: [String]
            let legacy: Bool
            let listProjectID: UUID?
            let pendingProposals: Int
            let maxPendingProposals: Int
            let eventsCursor: String
            let rateLimitPerMinute: Int
            let dailyCreateCap: Int
        }
        guard let me = identity, let hub else {
            return .ok(Result(agent: nil, scopes: AgentScope.allCases.map(\.rawValue), legacy: false, listProjectID: nil,
                              pendingProposals: 0, maxPendingProposals: 15, eventsCursor: "0",
                              rateLimitPerMinute: 60, dailyCreateCap: 40))
        }
        return .ok(Result(agent: Agent(slug: me.slug, displayName: me.displayName),
                          scopes: AgentScope.allCases.filter { me.scopes.has($0) }.map(\.rawValue),
                          legacy: me.isLegacy,
                          listProjectID: hub.agent(id: me.agentID)?.listProjectID,
                          pendingProposals: hub.pendingProposals(agentID: me.agentID, store: store),
                          maxPendingProposals: me.maxPendingProposals,
                          eventsCursor: String(hub.ackedCursor(agentID: me.agentID)),
                          rateLimitPerMinute: me.rateLimitPerMinute, dailyCreateCap: me.dailyCreateCap))
    }

    // MARK: - propose_tasks

    func proposeTasks(_ arguments: Data) -> MCPToolOutcome {
        let params: MCPParams.ProposeTasks
        do { params = try decodeParams(MCPParams.ProposeTasks.self, arguments, tool: "propose_tasks") } catch { return MCPToolOutcome.from(error) }
        let title = params.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 200 else {
            return .error(.invalidParams, message: "title must be 1-200 characters", data: ["field": "title"])
        }
        guard (1...20).contains(params.tasks.count) else {
            return .error(.invalidParams, message: "tasks must hold 1-20 entries, got \(params.tasks.count)", data: ["field": "tasks"])
        }
        let batch = cleanContext(params.context)
        if let p = batch.problem { return .error(.invalidParams, message: p, data: ["field": "context"]) }

        // Everything is validated before anything is written, so a bad item creates nothing.
        struct Plan { let title: String; let due: Int?; let planned: Int?; let priority: KPriority
            let project: KProject?; let subtasks: [String]; let context: AgentContext? }
        var plans: [Plan] = []
        for (i, t) in params.tasks.enumerated() {
            let name = "tasks[\(i)]"
            let tt = t.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if tt.isEmpty { return .error(.invalidParams, message: "\(name).title must not be empty", data: ["field": "\(name).title"]) }
            if let e = lengthError(title: tt) { return e }
            for s in t.subtasks ?? [] {
                if s.count > 120 {
                    return .error(.invalidParams, message: "\(name).subtasks entry is \(s.count) characters; the limit is 120", data: ["field": "\(name).subtasks"])
                }
                if let e = lengthError(title: s) { return e }
            }
            var due: Int?, planned: Int?
            if let raw = t.due {
                let p = parseDay(raw, field: "\(name).due"); if let e = p.error { return e }; due = p.day
            }
            if let raw = t.plannedDay {
                let p = parseDay(raw, field: "\(name).plannedDay"); if let e = p.error { return e }; planned = p.day
            }
            var project: KProject?
            if let n = t.project {
                guard let found = resolveProject(n) else {
                    return .error(.notFound, message: "no project matching \(n)", data: ["value": n, "field": "\(name).project"])
                }
                project = found
            }
            let own = cleanContext(t.context)
            if let p = own.problem { return .error(.invalidParams, message: p, data: ["field": "\(name).context"]) }
            plans.append(Plan(title: tt, due: due, planned: planned, priority: t.priority?.kPriority ?? .none,
                              project: project, subtasks: t.subtasks ?? [], context: own.context ?? batch.context))
        }

        let proposalID = UUID()
        var ids: [UUID] = []
        for plan in plans {
            let t = store.createNoUndo(title: plan.title, notes: "", project: plan.project, status: .todo,
                                       priority: plan.priority, dueDay: plan.due)
            var ctx = plan.context ?? AgentContext()
            ctx.kind = "task"
            ctx.proposalID = proposalID
            ctx.proposalTitle = title
            store.updateNoUndo(t.id) { task in
                task.needsTriage = false
                task.source = self.sourceTag
                if let d = plan.planned { task.plannedDay = d }
            }
            for s in plan.subtasks { store.addSubtaskNoUndo(t.id, title: s) }
            for field in TriageFieldKind.allCases { store.lockField(field, on: t.id) }
            stampAgentTask(t.id, context: ctx, pending: true)
            ids.append(t.id)
        }
        struct Result: Encodable { let proposalID: UUID; let taskIDs: [UUID]; let review: String }
        return .ok(Result(proposalID: proposalID, taskIDs: ids, review: "pending"))
    }

    // MARK: - propose_update

    func proposeUpdate(_ arguments: Data) -> MCPToolOutcome {
        let params: MCPParams.ProposeUpdate
        do { params = try decodeParams(MCPParams.ProposeUpdate.self, arguments, tool: "propose_update") } catch { return MCPToolOutcome.from(error) }
        guard let target = store.task(params.id) else { return .error(.notFound, message: "no task \(params.id)") }
        if let me = identity, owns(target, me) {
            return .error(.invalidState, message: "you own this task; change it with update_task", data: ["hint": "use update_task"])
        }
        if let why = params.why, why.count > AgentContext.maxWhy {
            return .error(.invalidParams, message: "why is \(why.count) characters; the limit is \(AgentContext.maxWhy)", data: ["field": "why"])
        }
        if let problem = AgentPatch.problem(params.patch, store: store) {
            return .error(.invalidParams, message: problem, data: ["field": "patch"])
        }
        let proposalID = UUID()
        var ctx = AgentContext()
        ctx.kind = "update"
        ctx.why = params.why
        ctx.proposalID = proposalID
        ctx.proposalTitle = target.title
        ctx.update = .init(targetID: target.id, patch: params.patch, why: params.why)
        let shadowTitle = String("Update: \(target.title)".prefix(MCPLimits.maxTitleCharacters))
        let shadow = store.createNoUndo(title: shadowTitle, notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
        store.updateNoUndo(shadow.id) { $0.needsTriage = false; $0.source = self.sourceTag }
        for field in TriageFieldKind.allCases { store.lockField(field, on: shadow.id) }
        stampAgentTask(shadow.id, context: ctx, pending: true)
        struct Result: Encodable { let proposalID: UUID; let proposalTaskID: UUID; let review: String }
        return .ok(Result(proposalID: proposalID, proposalTaskID: shadow.id, review: "pending"))
    }

    // MARK: - comment_task

    func commentTask(_ arguments: Data) -> MCPToolOutcome {
        let params: MCPParams.CommentTask
        do { params = try decodeParams(MCPParams.CommentTask.self, arguments, tool: "comment_task") } catch { return MCPToolOutcome.from(error) }
        let text = params.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...280).contains(text.count) else {
            return .error(.invalidParams, message: "text must be 1-280 characters", data: ["field": "text"])
        }
        guard let t = store.task(params.id) else { return .error(.notFound, message: "no task \(params.id)") }
        var ctx = AgentContext.decode(t.contextJSON) ?? AgentContext()
        let by = identity?.actor ?? "me"
        ctx.append(comment: .init(at: Date(), by: by, text: text))
        store.updateNoUndo(t.id) { $0.contextJSON = ctx.encoded() }
        if let hub {
            // The task's person hears it; an unowned task tells its commenter's own log only.
            hub.append(actor: by, verb: ActivityVerb.commented, taskID: t.id, agentID: t.agentID ?? identity?.agentID,
                       payload: ["title": .string(t.title), "note": .string(text)])
        }
        struct Result: Encodable { let id: UUID; let comments: Int }
        return .ok(Result(id: t.id, comments: ctx.comments?.count ?? 0))
    }

    // MARK: - events_poll / events_ack

    func eventsPoll(_ arguments: Data) -> MCPToolOutcome {
        let params: MCPParams.EventsPoll
        do { params = try decodeParams(MCPParams.EventsPoll.self, arguments, tool: "events_poll") } catch { return MCPToolOutcome.from(error) }
        guard let hub, let me = identity else {
            return .error(.invalidState, message: "events need an agent identity: connect with an agent token (Settings > Agents)")
        }
        var since = hub.ackedCursor(agentID: me.agentID)
        if let raw = params.since {
            guard let n = Int(raw), n >= 0 else {
                return .error(.invalidParams, message: "since must be an event cursor (digits), got \(raw)", data: ["field": "since"])
            }
            since = n
        }
        var kinds: Set<String>?
        if let k = params.kinds {
            let bad = Set(k).subtracting(ActivityVerb.delivered).sorted()
            if !bad.isEmpty {
                return .error(.invalidParams, message: "unknown event kind \(bad.joined(separator: ", "))",
                              data: ["field": "kinds", "accepted": ActivityVerb.delivered.sorted()])
            }
            kinds = Set(k)
        }
        if let f = params.format, !["json", "md"].contains(f) {
            return .error(.invalidParams, message: "format must be json or md", data: ["field": "format"])
        }
        let limit = params.limit ?? 50
        guard (1...200).contains(limit) else { return .error(.invalidParams, message: "limit must be 1-200", data: ["field": "limit"]) }
        if let w = params.waitSeconds, w < 0 { return .error(.invalidParams, message: "waitSeconds must be 0-55", data: ["field": "waitSeconds"]) }

        hub.sync(store: store)
        let found = hub.events(for: me, since: since, kinds: kinds, limit: limit)
        let iso = ISO8601DateFormatter()
        var entries: [AnyEncodable] = []
        for row in found.events {
            let task = row.taskID.flatMap { store.taskIncludingDeleted($0) }
            let event = DigestEvent(row: row, title: task?.title)
            let p = AgentHub.payload(row)
            var taskObj: [String: Any] = ["id": row.taskID?.uuidString ?? NSNull(), "title": event.title]
            if let task {
                taskObj = (jsonObject(MCPTaskCompact(task, blocked: false)) as? [String: Any]) ?? taskObj
                if let c = AgentJSON.parse(task.contextJSON ?? "") { taskObj["context"] = AgentJSON.object(c).any }
            }
            var result: [String: Any] = ["by": row.actor, "completedAt": iso.string(from: row.at)]
            for key in ["outcome", "note", "decision", "reason", "verdict", "comment"] { if let v = p[key]?.string { result[key] = v } }
            if !event.editedFields.isEmpty { result["editedFields"] = event.editedFields }
            if let task { result["openSubtasksLeft"] = task.orderedChildren.filter { KStatus.open.contains($0.status) }.count }
            let memory = EventDigest.memory(for: event)
            entries.append(AnyEncodable([
                "seq": String(row.seq), "at": iso.string(from: row.at), "kind": row.verb, "actor": row.actor,
                "task": taskObj, "result": result,
                "memory": ["markdown": memory.markdown, "json": AgentJSON.object(memory.json).any],
            ] as [String: Any]))
        }
        struct Result: Encodable { let events: [AnyEncodable]; let cursor: String; let more: Bool; let digest: String? }
        var digest: String?
        if params.format == "md" {
            digest = EventDigest.markdown(found.events.map { row in DigestEvent(row: row, title: row.taskID.flatMap { store.taskIncludingDeleted($0)?.title }) })
        }
        return .ok(Result(events: entries, cursor: String(found.events.last?.seq ?? since), more: found.more, digest: digest))
    }

    func eventsAck(_ arguments: Data) -> MCPToolOutcome {
        let params: MCPParams.EventsAck
        do { params = try decodeParams(MCPParams.EventsAck.self, arguments, tool: "events_ack") } catch { return MCPToolOutcome.from(error) }
        guard let hub, let me = identity else {
            return .error(.invalidState, message: "events need an agent identity: connect with an agent token (Settings > Agents)")
        }
        guard let upTo = Int(params.upTo), upTo >= 0 else {
            return .error(.invalidParams, message: "upTo must be an event cursor (digits), got \(params.upTo)", data: ["field": "upTo"])
        }
        let cursor = hub.ack(agentID: me.agentID, upTo: min(upTo, hub.maxSeq()))
        struct Result: Encodable { let cursor: String }
        return .ok(Result(cursor: String(cursor)))
    }

    // MARK: - next

    func next(_ arguments: Data) -> MCPToolOutcome {
        let params: MCPParams.Next
        do { params = try decodeParams(MCPParams.Next.self, arguments, tool: "next") } catch { return MCPToolOutcome.from(error) }
        let day = today()
        let lookup = store.allTasks()
        var candidates = nextProvider?()
        var source = "shown"
        if candidates?.ids.isEmpty != false {
            candidates = MCPNextCandidates(listName: "Today", ids: todayHeadIDs(lookup: lookup, day: day, limit: 8), pinned: nil, barTaskID: nil)
            source = "today"
        }
        guard let c = candidates else { return .ok(NextResult(task: nil, reason: nil, barTaskID: nil, list: nil, source: source)) }
        let rows = c.ids.compactMap { id in lookup.first { $0.id == id } }
        var pick: KTask?
        var reason: String?
        if let e = params.energy {
            let level: KEnergyLevel = e == .low ? .low : e == .mid ? .mid : .high
            for row in rows where NextEligibility.isEligible(row, lookup: lookup) {
                if let cand = ranking.candidates(energy: level, count: 1, maxDeep: level == .high, today: day, tasks: [row]).first {
                    pick = row; reason = cand.reason; break
                }
            }
        } else {
            pick = NextEligibility.pick(pinned: c.pinned, rows: rows, lookup: lookup)
            if let p = pick {
                reason = p.id == c.pinned ? "Pinned by the owner"
                    : ranking.candidates(energy: .high, count: 1, maxDeep: true, today: day, tasks: [p]).first?.reason
                    ?? "First eligible task of \(c.listName)"
            }
        }
        let blocked = pick.map { store.isBlocked($0.id) } ?? false
        return .ok(NextResult(task: pick.map { MCPTaskCompact($0, blocked: blocked) }, reason: reason,
                              barTaskID: c.barTaskID ?? pick?.id, list: c.listName, source: source))
    }

    struct NextResult: Encodable {
        let task: MCPTaskCompact?
        let reason: String?
        let barTaskID: UUID?
        let list: String?
        let source: String
    }

    /// First `limit` eligible Today tasks in the default sort (the Today fallback for `next`).
    func todayHeadIDs(lookup: [KTask], day: Int, limit: Int) -> [UUID] {
        let members = lookup.filter { NextFallback.isToday($0, today: day) }
        let sorted = KTaskSorter.sorted(members, by: KSortDescriptor.default)
        return Array(sorted.lazy.filter { NextEligibility.isEligible($0, lookup: lookup) }.prefix(limit).map(\.id))
    }
}
#endif
