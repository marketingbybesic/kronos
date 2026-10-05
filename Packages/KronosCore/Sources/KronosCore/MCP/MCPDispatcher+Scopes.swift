#if os(macOS)
// What a caller may do. Without an identity the caller is the person's own process and nothing is
// refused. With one, every tool call passes through `authorize` before any work: rate limit,
// scope, and ownership of the tasks it names. Aliases are resolved first, so `upnext_set` is
// judged exactly like `ordo_set`.

import Foundation

extension MCPDispatcher {

    /// What a tool needs beyond ownership.
    private enum Need { case read, propose, writeOwn, comment, ordo, rules, rulesDelete, structure }

    private func need(_ tool: MCPTool) -> Need {
        switch tool.canonical {
        case .listTasks, .getTask, .ordoGet, .rulesList, .listProjects, .listAreas, .listLabels, .whoami, .eventsPoll, .eventsAck, .next:
            return .read
        case .createTask, .proposeTasks, .proposeUpdate: return .propose
        case .commentTask: return .comment
        case .updateTask, .completeTask, .deleteTask, .restoreTask, .addSubtask, .toggleSubtask: return .writeOwn
        case .ordoSet: return .ordo
        case .rulesAdd: return .rules
        case .rulesDelete: return .rulesDelete
        case .upnextGet, .upnextSet: return .read
        case .createLabel, .updateLabel, .createProject, .updateProject, .createArea, .updateArea, .deleteArea, .moveTask:
            return .structure
        }
    }

    private func forbidden(_ message: String, scope: AgentScope? = nil, hint: String? = nil) -> MCPToolOutcome {
        var data: [String: Any] = [:]
        if let scope { data["requiredScope"] = scope.rawValue }
        if let hint { data["hint"] = hint }
        return .error(.forbidden, message: message, data: data.isEmpty ? nil : data)
    }

    /// The task an agent owns: it created it, was assigned it, or it is a step of such a task.
    func owns(_ task: KTask, _ me: AgentIdentity) -> Bool {
        if task.agentID == me.agentID { return true }
        if let parent = task.parentID, let p = store.taskIncludingDeleted(parent), p.agentID == me.agentID { return true }
        return false
    }

    /// nil = allowed. Otherwise the refusal to send back.
    func authorize(_ tool: MCPTool, _ arguments: Data) -> MCPToolOutcome? {
        guard let me = identity, let hub else { return nil }

        if !skipRateLimit {
            let r = hub.limiter.consume(slug: me.slug, perMinute: me.rateLimitPerMinute)
            if !r.allowed {
                return .error(.rateLimited, message: "more than \(me.rateLimitPerMinute) calls a minute; retry in \(r.retryAfter) s",
                              data: ["retryAfter": r.retryAfter])
            }
        }
        let obj = (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] ?? [:]
        func uuid(_ key: String) -> UUID? { (obj[key] as? String).flatMap(UUID.init(uuidString:)) }

        switch need(tool) {
        case .read:
            guard me.scopes.has(.read) else { return forbidden("this agent may not read", scope: .read) }
        case .comment:
            guard me.scopes.has(.comment) else { return forbidden("this agent may not comment", scope: .comment) }
        case .propose:
            guard me.scopes.has(.propose) || me.scopes.has(.writeTrusted) else {
                return forbidden("this agent may not create or propose tasks", scope: .propose)
            }
            let count = tool.canonical == .proposeTasks ? ((obj["tasks"] as? [Any])?.count ?? 1) : 1
            if tool.canonical != .proposeUpdate, let capped = createCapError(me, adding: count) { return capped }
            let creatingPending = tool.canonical != .createTask || !me.scopes.has(.writeTrusted)
            if creatingPending {
                let pending = hub.pendingProposals(agentID: me.agentID, store: store)
                if pending >= me.maxPendingProposals {
                    return .error(.reviewBacklog, message: MCPLimitCodes.reviewBacklogMessage(pending: pending, max: me.maxPendingProposals),
                                  data: ["pending": pending, "limit": me.maxPendingProposals])
                }
            }
        case .writeOwn:
            let full = me.scopes.has(.writeAll)
            guard me.scopes.has(.writeOwn) || full else { return forbidden("this agent may not change tasks", scope: .writeOwn, hint: "use propose_update") }
            let target = tool.canonical == .addSubtask ? uuid("taskID") : uuid("id")
            if let target {
                // restore_task names a deleted task, so look through deletions too.
                guard let t = store.taskIncludingDeleted(target) else { return nil }   // NOT_FOUND comes from the handler
                // Full control reaches every task but never deletes or restores one that is not the agent's.
                let destructive = tool.canonical == .deleteTask || tool.canonical == .restoreTask
                if !owns(t, me) && (!full || destructive) {
                    let hint = tool.canonical == .deleteTask
                        ? "use propose_update" : "use propose_update or comment_task"
                    return forbidden("\(tool.name) works only on tasks you created or were assigned", scope: full ? nil : .writeOwn, hint: hint)
                }
                if let locked = verdictLock(tool, t, obj, me) { return locked }
            }
        case .ordo:
            let full = me.scopes.has(.writeAll)
            guard me.scopes.has(.writeOwn) || full else { return forbidden("this agent may not reorder Up next", scope: .writeOwn, hint: "use propose_update") }
            var named = Set<UUID>()
            if let top = uuid("top") { named.insert(top) }
            for raw in (obj["order"] as? [String]) ?? [] { if let u = UUID(uuidString: raw) { named.insert(u) } }
            // `order` also removes whatever it leaves out, so the tasks already queued count too.
            if obj["order"] != nil { for t in store.allTasks() where t.isInOrdo { named.insert(t.id) } }
            for id in named where !full {
                if let t = store.task(id), !owns(t, me) {
                    return forbidden("Up next holds tasks that are not yours; you may reorder only your own", scope: .writeOwn,
                                     hint: "use propose_update")
                }
            }
        case .rules:
            guard me.scopes.has(.propose) || me.scopes.has(.rulesPropose) else {
                return forbidden("this agent may not propose house rules", scope: .rulesPropose)
            }
        case .structure:
            guard me.scopes.has(.writeAll) else {
                return forbidden("\(tool.name) needs full control, which the owner grants per agent in Settings > Agents", scope: .writeAll,
                                 hint: "ask the owner to turn on Full control for this agent")
            }
        case .rulesDelete:
            guard me.scopes.has(.writeOwn) || me.scopes.has(.rulesPropose) else {
                return forbidden("this agent may not delete house rules", scope: .writeOwn)
            }
            if let id = uuid("id"), let rule = store.allRules(includeInactive: true).first(where: { $0.id == id }),
               rule.sourceRaw != KRule.agentSourceRaw {
                return forbidden("only rules an agent proposed can be deleted by an agent", hint: "ask the owner")
            }
        }
        return nil
    }

    /// The verdict on agent work (accept, reject, reopen) is the person's. A tool that would close or
    /// reopen a task waiting for that verdict is refused for every agent, with or without full control,
    /// so no agent can pass its own review (or anyone else's).
    private func verdictLock(_ tool: MCPTool, _ t: KTask, _ obj: [String: Any], _ me: AgentIdentity) -> MCPToolOutcome? {
        let changesState: Bool
        switch tool.canonical {
        case .completeTask: changesState = !(t.assigneeRaw == 1 && t.agentID == me.agentID)
        case .updateTask: changesState = obj["status"] != nil
        default: changesState = false
        }
        guard changesState else { return nil }
        // A task handed to another agent closes only through that agent's report and the person's check.
        let closes = tool.canonical == .completeTask || ["done", "canceled"].contains(obj["status"] as? String ?? "")
        let othersAssignment = t.assigneeRaw == 1 && t.agentID != nil && t.agentID != me.agentID && closes
        guard othersAssignment || t.reviewRaw == ReviewState.awaitingCheck
                || (t.reviewRaw == ReviewState.pending && !owns(t, me)) else { return nil }
        return forbidden("the verdict on agent work (accept, reject, reopen) is the owner's alone", hint: "read the outcome with get_task or events_poll")
    }

    /// RATE_LIMITED when `adding` more tasks would pass the agent's daily cap.
    private func createCapError(_ me: AgentIdentity, adding: Int) -> MCPToolOutcome? {
        guard let hub else { return nil }
        let made = hub.createsToday(agent: me)
        guard made + adding > me.dailyCreateCap else { return nil }
        return .error(.rateLimited, message: "daily limit of \(me.dailyCreateCap) created tasks reached (\(made) today)",
                      data: ["limit": me.dailyCreateCap, "createdToday": made])
    }

    // MARK: - Recording

    /// Runs a tool and, for an identified agent, logs what it changed (with before values, so the
    /// change can be reverted) in the activity log.
    func dispatchRecording(_ tool: MCPTool, arguments: Data) -> MCPToolOutcome {
        guard let me = identity, let hub, tool.isMutating else { return dispatch(tool, arguments: arguments) }
        let obj = (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] ?? [:]
        let target: UUID? = {
            switch tool.canonical {
            case .updateTask, .completeTask, .deleteTask, .restoreTask, .moveTask: return (obj["id"] as? String).flatMap(UUID.init(uuidString:))
            default: return nil
            }
        }()
        let before = target.flatMap { store.taskIncludingDeleted($0) }.map(TaskSnapshot.init)
        let outcome = dispatch(tool, arguments: arguments)
        switch tool.canonical {
        case .createLabel, .updateLabel, .createProject, .updateProject, .createArea, .updateArea, .deleteArea:
            // Structure has no task to revert; the log still says who changed what.
            if !outcome.isError {
                var payload: [String: AgentJSON] = ["tool": .string(tool.name)]
                for key in ["id", "name"] { if let v = obj[key] as? String { payload[key] = .string(v) } }
                hub.append(actor: me.actor, verb: ActivityVerb.structure, agentID: me.agentID, payload: payload)
            }
            return outcome
        default: break
        }
        guard !outcome.isError, let target else { return outcome }
        let after = store.taskIncludingDeleted(target).map(TaskSnapshot.init)
        let actor = me.actor
        switch tool.canonical {
        case .updateTask, .moveTask:
            guard let before, let after else { break }
            let d = TaskSnapshot.diff(before, after)
            if !d.after.isEmpty {
                hub.append(actor: actor, verb: ActivityVerb.updated, taskID: target, agentID: me.agentID,
                           payload: ["before": .object(d.before), "after": .object(d.after)])
            }
            let wasOpen = before.values["status"]?.int.flatMap(KStatus.init(rawValue:)).map { !KStatus.closed.contains($0) } ?? true
            let isOpen = after.values["status"]?.int.flatMap(KStatus.init(rawValue:)).map { !KStatus.closed.contains($0) } ?? true
            if wasOpen && !isOpen {
                hub.append(actor: actor, verb: ActivityVerb.completed, taskID: target, agentID: owner(of: target, me),
                           payload: ["previousStatus": before.values["status"] ?? .null])
            } else if !wasOpen && isOpen {
                hub.append(actor: actor, verb: ActivityVerb.reopened, taskID: target, agentID: owner(of: target, me))
            }
        case .completeTask:
            if let before, store.task(target).map({ KStatus.closed.contains($0.status) }) == true {
                hub.append(actor: actor, verb: ActivityVerb.completed, taskID: target, agentID: owner(of: target, me),
                           payload: ["previousStatus": before.values["status"] ?? .null])
            }
        case .deleteTask:
            hub.append(actor: actor, verb: ActivityVerb.deleted, taskID: target, agentID: owner(of: target, me))
        case .restoreTask:
            hub.append(actor: actor, verb: ActivityVerb.restored, taskID: target, agentID: owner(of: target, me))
        default: break
        }
        return outcome
    }

    private func owner(of id: UUID, _ me: AgentIdentity) -> UUID {
        store.taskIncludingDeleted(id)?.agentID ?? me.agentID
    }
}
#endif
