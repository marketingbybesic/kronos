// "Revert today's changes" for one agent: replays the inverse of what the agent did since local
// midnight, newest first. A field is put back only when it still holds the value the agent
// wrote, so an edit the person made afterwards is never overwritten. Each reverted row is marked,
// so a second run does nothing.

import Foundation

public struct RevertSummary: Equatable, Sendable {
    public var created = 0      // tasks the agent created, now deleted
    public var updated = 0      // field edits put back
    public var completed = 0    // completions undone
    public var deleted = 0      // deletions undone
    public var skipped = 0      // person edited the field since, or the task is gone
    public var total: Int { created + updated + completed + deleted }
}

extension AgentHub {

    @discardableResult
    public func revertToday(agentID: UUID, store: any TaskStoring) -> RevertSummary {
        var summary = RevertSummary()
        guard let a = agent(id: agentID) else { return summary }
        let actor = "agent:\(a.slug)"
        let start = Calendar.current.startOfDay(for: now())
        let todays = rows().filter { $0.actor == actor && $0.at >= start && Self.payload($0)["reverted"]?.bool != true }
            .sorted { $0.seq > $1.seq }

        // One confirm-gated bulk action: every write below REGISTERS UNDO (the non-NoUndo twin
        // of each store method), and groupedUndo collapses the whole bulk revert into ONE Cmd-Z
        // step, matching every other mutation path's safety net (TaskStore+Mutations.swift's
        // complete(_:), "REGISTERS UNDO").
        store.groupedUndo("Revert Today") {
            for row in todays {
                guard ActivityVerb.writes.contains(row.verb), let taskID = row.taskID else { continue }
                let p = Self.payload(row)
                switch row.verb {
                case ActivityVerb.created:
                    if store.task(taskID) != nil { store.softDelete(taskID); summary.created += 1 } else { summary.skipped += 1 }
                case ActivityVerb.updated:
                    guard store.task(taskID) != nil else { summary.skipped += 1; continue }
                    let before = p["before"]?.object ?? [:], after = p["after"]?.object ?? [:]
                    var any = false
                    for (key, wrote) in after {
                        guard let current = store.task(taskID).map(TaskSnapshot.init)?.values[key] else { continue }
                        if current == wrote, let old = before[key] {
                            TaskSnapshot.restore(key, old, on: taskID, store: store)
                            any = true
                        } else {
                            summary.skipped += 1
                        }
                    }
                    if any { summary.updated += 1 }
                case ActivityVerb.completed:
                    guard store.task(taskID) != nil else { summary.skipped += 1; continue }
                    let prev = p["previousStatus"]?.int.flatMap(KStatus.init(rawValue:)) ?? .todo
                    store.setStatus(taskID, prev)
                    summary.completed += 1
                case ActivityVerb.deleted:
                    if store.taskIncludingDeleted(taskID) != nil { store.restore(taskID); summary.deleted += 1 } else { summary.skipped += 1 }
                case ActivityVerb.restored:
                    if store.task(taskID) != nil { store.softDelete(taskID); summary.deleted += 1 }
                case ActivityVerb.doneByAgent:
                    store.update(taskID) { $0.reviewRaw = 0 }
                    summary.completed += 1
                default:
                    continue
                }
                var marked = p
                marked["reverted"] = .bool(true)
                row.payloadJSON = AgentJSON.encoded(marked)
            }
        }
        save()
        if summary.total > 0 {
            append(actor: "me", verb: ActivityVerb.reverted, agentID: agentID, payload: [
                "created": .number(Double(summary.created)), "updated": .number(Double(summary.updated)),
                "completed": .number(Double(summary.completed)), "deleted": .number(Double(summary.deleted)),
            ])
        }
        return summary
    }
}
