// Turns what the person does in the app (complete, reopen, approve, reject, delete, delegate) into
// events an agent can hear. The app's store has no hook for this, so the log compares each
// agent-owned task with what it already reported and writes one event per difference. Safe to
// run as often as wanted: a second run over an unchanged store adds nothing.

import Foundation
import SwiftData

extension AgentHub {

    private enum DoneFact { case completed, doneByAgent, reopened }

    private struct Life {
        var agentID: UUID
        var seen = false          // created or assigned was reported
        var wasPending = false    // it began as a proposal, so approval is an event
        var approved = false
        var rejected = false
        var deleted = false
        var done: DoneFact?
    }

    private func lifecycle() -> [UUID: Life] {
        var map: [UUID: Life] = [:]
        for r in rows() {
            guard let taskID = r.taskID, let agentID = r.agentID else { continue }
            var l = map[taskID] ?? Life(agentID: agentID)
            switch r.verb {
            case ActivityVerb.created, ActivityVerb.assigned:
                l.seen = true
                if r.verb == ActivityVerb.created { l.wasPending = AgentHub.payload(r)["review"]?.int == ReviewState.pending }
            case ActivityVerb.approved: l.approved = true
            case ActivityVerb.rejected: l.rejected = true
            case ActivityVerb.deleted: l.deleted = true
            case ActivityVerb.restored: l.deleted = false
            case ActivityVerb.completed: l.done = .completed
            case ActivityVerb.doneByAgent: l.done = .doneByAgent
            case ActivityVerb.reopened: l.done = .reopened
            default: continue
            }
            map[taskID] = l
        }
        return map
    }

    /// Reports every change since the last run. Returns how many events it wrote.
    @discardableResult
    public func sync(store: any TaskStoring) -> Int {
        var life = lifecycle()
        var live: [UUID: KTask] = [:]
        for t in store.allTasksIncludingSubtasks() where t.agentID != nil { live[t.id] = t }
        var ids = Set(live.keys)
        // A task that left the live list (deleted or purged) is still one of ours.
        for id in life.keys where live[id] == nil { ids.insert(id) }

        var written = 0
        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let t = live[id] ?? store.taskIncludingDeleted(id) else {
                // Gone for good: report it once.
                if let l = life[id], !l.deleted, !l.rejected {
                    append(actor: "me", verb: ActivityVerb.deleted, taskID: id, agentID: l.agentID)
                    written += 1
                }
                continue
            }
            guard let agentID = t.agentID ?? life[id]?.agentID else { continue }
            var l = life[id] ?? Life(agentID: agentID)
            let result = AgentTaskResult.decode(t.resultJSON)
            var base: [String: AgentJSON] = ["title": .string(t.title)]
            // The person's verdict and word travel with the event (Accept, Reject, send back).
            if result?.by == "me", let v = result?.verdict {
                base["verdict"] = .string(v)
                if let c = result?.verdictComment { base["comment"] = .string(c) }
            }
            func emit(_ verb: String, _ extra: [String: AgentJSON] = [:], at: Date? = nil) {
                append(actor: "me", verb: verb, taskID: id, agentID: agentID,
                       payload: base.merging(extra) { $1 }, at: at)
                written += 1
            }

            if !l.seen, t.assigneeRaw == 1, t.reviewRaw != 1 {
                emit(ActivityVerb.assigned)
                l.seen = true
            }
            if t.deletedAt != nil {
                // A spent update proposal, or a proposal merged into an open task, is approved,
                // not "deleted": report that once.
                let merged = result?.decision == "merge"
                if t.reviewRaw == 2, merged || AgentContext.decode(t.contextJSON)?.kind == "update" {
                    if l.wasPending, !l.approved {
                        var extra: [String: AgentJSON] = ["decision": .string(result?.decision ?? "approve")]
                        if let f = result?.editedFields, !f.isEmpty { extra["editedFields"] = .array(f.map(AgentJSON.string)) }
                        if merged, let into = result?.mergedInto { extra["mergedInto"] = .string(into.uuidString) }
                        if merged, let r = result?.reason { extra["reason"] = .string(r) }
                        emit(ActivityVerb.approved, extra)
                        l.approved = true
                    }
                } else if t.reviewRaw == 3 {
                    if !l.rejected {
                        var extra: [String: AgentJSON] = [:]
                        if let r = result?.reason { extra["reason"] = .string(r) }
                        emit(ActivityVerb.rejected, extra, at: t.deletedAt)
                        l.rejected = true
                    }
                } else if !l.deleted {
                    emit(ActivityVerb.deleted, at: t.deletedAt)
                    l.deleted = true
                }
                life[id] = l
                continue
            }
            if l.deleted { l.deleted = false }
            if t.reviewRaw == 2, l.wasPending, !l.approved {
                var extra: [String: AgentJSON] = ["decision": .string(result?.decision ?? "approve")]
                if let f = result?.editedFields, !f.isEmpty { extra["editedFields"] = .array(f.map(AgentJSON.string)) }
                emit(ActivityVerb.approved, extra)
                l.approved = true
            }
            base["outcome"] = .string(t.status == .canceled ? "canceled" : "done")
            if let n = result?.note { base["note"] = .string(n) }
            if KStatus.closed.contains(t.status) {
                if l.done != .completed {
                    emit(ActivityVerb.completed, at: t.completedAt)
                    l.done = .completed
                }
            } else if t.reviewRaw != 4, l.done == .completed || l.done == .doneByAgent {
                base["outcome"] = nil
                emit(ActivityVerb.reopened)
                l.done = .reopened
            }
            life[id] = l
        }
        return written
    }
}
