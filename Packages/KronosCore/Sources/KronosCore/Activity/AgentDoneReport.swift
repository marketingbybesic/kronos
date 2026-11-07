// The one store path behind "an agent reports a task it holds as done": `complete_task` on a
// task delegated to the calling agent, and `RunStore.finish(outcome: .done)` (Kronos v1.2 "run
// contract", Phase 1 slice A3) both call this — one path, no copy — so a run that finishes done
// lands in Review exactly like an agent-completed task always has: `awaitingCheck`, or
// auto-approved when the agent holds the person-granted `done.trusted` scope.

import Foundation

@MainActor
public enum AgentDoneReport {

    public struct Outcome: Equatable, Sendable {
        public let autoApproved: Bool
        /// "awaitingCheck" or "autoApproved".
        public let review: String
    }

    @discardableResult
    public static func reportDone(_ id: UUID, agent: AgentIdentity, note: String?, links: [AgentContext.Link]?,
                                  store: any TaskStoring, hub: AgentHub?, now: Date = Date()) -> Outcome {
        let title = store.task(id)?.title ?? ""
        var result = AgentTaskResult()
        result.outcome = "done"
        result.by = agent.actor
        result.note = note
        result.links = links
        result.completedAt = now

        if agent.scopes.has(.doneTrusted) {
            result.verdict = AgentReview.accepted
            result.verdictAt = now
            result.decision = "auto"
            store.updateNoUndo(id) { t in
                t.agentID = agent.agentID
                t.assigneeRaw = 1
                t.reviewRaw = ReviewState.approved
                t.resultJSON = result.encoded()
            }
            store.completeNoUndo(id)
            hub?.append(actor: agent.actor, verb: ActivityVerb.doneByAgent, taskID: id, agentID: agent.agentID,
                       payload: ["title": .string(title), "auto": .bool(true)], at: now)
            return Outcome(autoApproved: true, review: "autoApproved")
        }

        store.updateNoUndo(id) { t in
            t.agentID = agent.agentID
            t.assigneeRaw = 1
            t.reviewRaw = ReviewState.awaitingCheck
            t.resultJSON = result.encoded()
        }
        hub?.append(actor: agent.actor, verb: ActivityVerb.doneByAgent, taskID: id, agentID: agent.agentID,
                   payload: ["title": .string(title)], at: now)
        return Outcome(autoApproved: false, review: "awaitingCheck")
    }
}
