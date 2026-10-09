#if os(macOS)
// L4 — MCP. complete_task, delete_task, restore_task, and the
// jsonObject encoding helper. Split from MCPDispatcher+Tools.swift to
// keep every file under 500 lines.

import Foundation

extension MCPDispatcher {

    // MARK: - complete_task

    func completeTask(_ arguments: Data) -> MCPToolOutcome {
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
        // A task handed to an agent is not closed by the agent: it goes back to the person to
        // check, unless the agent holds the person-granted done.trusted scope, in which case it
        // closes the task itself and the person's check is skipped.
        if let me = identity, t.assigneeRaw == 1, t.agentID == me.agentID {
            var result = AgentTaskResult()
            result.outcome = "done"
            result.by = me.actor
            result.note = extras.result?.note
            result.links = extras.result?.links
            result.completedAt = Date()
            if me.scopes.has(.doneTrusted) {
                result.verdict = AgentReview.accepted
                result.verdictAt = result.completedAt
                result.decision = "auto"
                store.updateNoUndo(params.id) { $0.reviewRaw = ReviewState.approved; $0.resultJSON = result.encoded() }
                store.completeNoUndo(params.id)
                hub?.append(actor: me.actor, verb: ActivityVerb.doneByAgent, taskID: params.id, agentID: me.agentID,
                            payload: ["title": .string(t.title), "auto": .bool(true)])
                guard let final = store.task(params.id) else {
                    return .error(.internalError, message: "task vanished during completion")
                }
                struct AutoAccepted: Encodable { let completed: Bool; let review: String; let task: MCPTaskFull }
                return .ok(AutoAccepted(completed: true, review: "autoApproved",
                                        task: MCPTaskFull(final, today: today(), blocked: store.isBlocked(final.id))))
            }
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

    func deleteTask(_ arguments: Data) -> MCPToolOutcome {
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

    func restoreTask(_ arguments: Data) -> MCPToolOutcome {
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
