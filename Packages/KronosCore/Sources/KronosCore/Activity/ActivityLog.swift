// The activity log: audit trail of what agents did and outbox of what an agent still has to
// hear. One append-only table (KActivity) answers "what did Codex do today" and "what should
// Codex hear". Rows live in the device-local store and never sync.

import Foundation
import SwiftData

public enum ActivityVerb {
    // Written by an agent's own call (audit, never reported back to its author).
    public static let created = "task.created"
    public static let updated = "task.updated"
    public static let doneByAgent = "task.doneByAgent"
    public static let restored = "task.restored"
    public static let reverted = "agent.reverted"
    /// A project, area or label an agent with full control created or changed (no task id).
    public static let structure = "structure.changed"
    // Reported to the agent that owns the task.
    public static let completed = "task.completed"
    public static let approved = "task.approved"
    public static let rejected = "task.rejected"
    public static let reopened = "task.reopened"
    public static let deleted = "task.deleted"
    public static let assigned = "task.assigned"
    public static let commented = "task.commented"
    public static let edited = "task.edited"
    /// The person marked, or unmarked, a task reviewed (finish-round-1 phase-gate). Independent
    /// of `approved`/`rejected`: those report the agent-proposal verdict; these report the
    /// person's own "I looked at this" mark, which exists on any task and is derived — for
    /// `review_status` and `events_poll` alike — from the LATEST of these two rows per task in
    /// this device-local, non-syncing activity log (no separate KTask field: a schema change
    /// there would break every already-persisted V2 store's entity-hash match, see
    /// SchemaV1Frozen.swift's header).
    public static let reviewed = "task.reviewed"
    public static let unreviewed = "task.unreviewed"
    // Bookkeeping.
    public static let ack = "cursor.ack"

    /// Verbs an agent may hear about.
    public static let delivered: Set<String> = [completed, approved, rejected, reopened, deleted, assigned, commented, edited, reviewed, unreviewed]
    /// Verbs that count as a write by an agent (the 7-day figure in Settings).
    public static let writes: Set<String> = [created, updated, completed, deleted, restored, doneByAgent, commented, structure]
}

extension AgentHub {

    // MARK: - Append and read

    func maxSeq() -> Int {
        var d = FetchDescriptor<KActivity>(sortBy: [SortDescriptor(\.seq, order: .reverse)])
        d.fetchLimit = 1
        return ((try? context.fetch(d)) ?? []).first?.seq ?? 0
    }

    @discardableResult
    public func append(actor: String, verb: String, taskID: UUID? = nil, agentID: UUID? = nil,
                       payload: [String: AgentJSON] = [:], at: Date? = nil) -> KActivity {
        let row = KActivity(seq: maxSeq() + 1, actor: actor, verb: verb, taskID: taskID, agentID: agentID,
                            payloadJSON: payload.isEmpty ? "" : AgentJSON.encoded(payload), at: at ?? now())
        if let agentID, ActivityVerb.delivered.contains(verb), let a = agent(id: agentID),
           let target = a.webhookURL, !target.isEmpty, actor != "agent:\(a.slug)" {
            row.webhookStateRaw = 1
        }
        context.insert(row)
        save()
        return row
    }

    // MARK: - Reviewed mark (finish-round-1 B3)

    /// Whether the person's "reviewed" phase-gate mark is currently set for this task: the
    /// newest of a `reviewed`/`unreviewed` row for it. Device-local, not synced, not a KTask
    /// field (see ActivityVerb.reviewed's doc comment for why).
    public func isReviewed(_ taskID: UUID) -> Bool {
        var latestSeq = -1, latestReviewed = false
        for row in rows() where row.taskID == taskID {
            guard row.verb == ActivityVerb.reviewed || row.verb == ActivityVerb.unreviewed else { continue }
            if row.seq > latestSeq { latestSeq = row.seq; latestReviewed = row.verb == ActivityVerb.reviewed }
        }
        return latestReviewed
    }

    /// Marks or unmarks a task reviewed. person-only by construction: called from the inspector
    /// and the task context menu, never from MCPDispatcher (review_status is read-only; no tool
    /// calls this). Not part of TaskStore's undo stack — the activity log is a device-local audit
    /// trail, not app state the store tracks.
    @discardableResult
    public func setReviewed(_ reviewed: Bool, taskID: UUID, agentID: UUID?) -> KActivity {
        append(actor: "me", verb: reviewed ? ActivityVerb.reviewed : ActivityVerb.unreviewed, taskID: taskID, agentID: agentID)
    }

    public func rows(since seq: Int = 0) -> [KActivity] {
        let d = FetchDescriptor<KActivity>(predicate: #Predicate { $0.seq > seq }, sortBy: [SortDescriptor(\.seq)])
        return (try? context.fetch(d)) ?? []
    }

    public var latestSeq: Int { maxSeq() }

    public func rows(from date: Date) -> [KActivity] {
        let d = FetchDescriptor<KActivity>(predicate: #Predicate { $0.at >= date }, sortBy: [SortDescriptor(\.seq)])
        return (try? context.fetch(d)) ?? []
    }

    public nonisolated static func payload(_ row: KActivity) -> [String: AgentJSON] { AgentJSON.parse(row.payloadJSON) ?? [:] }

    /// Events the agent should hear: about its tasks, never its own writes, never bookkeeping.
    public func events(for agent: AgentIdentity, since: Int, kinds: Set<String>? = nil,
                       limit: Int = 50) -> (events: [KActivity], more: Bool) {
        let wanted = kinds.map { $0.intersection(ActivityVerb.delivered) } ?? ActivityVerb.delivered
        let all = rows(since: since).filter {
            $0.agentID == agent.agentID && $0.actor != agent.actor && wanted.contains($0.verb)
        }
        let cap = max(1, limit)
        return (Array(all.prefix(cap)), all.count > cap)
    }

    // MARK: - Ack cursor

    public func ackedCursor(agentID: UUID) -> Int {
        rows().filter { $0.verb == ActivityVerb.ack && $0.agentID == agentID }
            .compactMap { Self.payload($0)["upTo"]?.int }.max() ?? 0
    }

    /// Moves the server-side cursor forward (never back) to `upTo`.
    @discardableResult
    public func ack(agentID: UUID, upTo: Int) -> Int {
        let current = ackedCursor(agentID: agentID)
        guard upTo > current else { return current }
        append(actor: "system", verb: ActivityVerb.ack, agentID: agentID, payload: ["upTo": .number(Double(upTo))])
        return upTo
    }

    // MARK: - Counts for limits and Settings

    public func createsToday(agent: AgentIdentity) -> Int {
        let start = Calendar.current.startOfDay(for: now())
        return rows().filter { $0.verb == ActivityVerb.created && $0.actor == agent.actor && $0.at >= start }.count
    }

    public func writeCount(agentID: UUID, days: Int) -> Int {
        guard let a = agent(id: agentID) else { return 0 }
        let since = now().addingTimeInterval(-Double(days) * 86_400)
        return rows().filter { $0.actor == "agent:\(a.slug)" && ActivityVerb.writes.contains($0.verb) && $0.at >= since }.count
    }

    /// Everything concerning one agent, newest first: its own writes plus what the person (or
    /// another agent sharing one of its tasks) did to it — approved/rejected/commented/
    /// reviewed/... Bookkeeping (`cursor.ack`) is excluded: never useful in a human-facing feed.
    /// Settings > Agents' per-agent activity view (finish-round-1 AgentLedgerView).
    public func activity(forAgentSlug slug: String) -> [KActivity] {
        guard let a = agent(slug: slug) else { return [] }
        return rows().filter { ($0.actor == "agent:\(slug)" || $0.agentID == a.id) && $0.verb != ActivityVerb.ack }
            .sorted { $0.seq > $1.seq }
    }

    /// Events not delivered yet to an agent's webhook, and those given up on.
    public func undelivered(agentID: UUID) -> (pending: Int, dead: Int) {
        let mine = rows().filter { $0.agentID == agentID }
        return (mine.filter { $0.webhookStateRaw == 1 }.count, mine.filter { $0.webhookStateRaw == 3 }.count)
    }

    /// Unreviewed proposals of an agent: a batch counts once, a single pending task once.
    public func pendingProposals(agentID: UUID, store: any TaskStoring) -> Int {
        var units = Set<UUID>()
        for t in store.allTasksIncludingSubtasks() where t.agentID == agentID && t.reviewRaw == 1 {
            units.insert(AgentContext.decode(t.contextJSON)?.proposalID ?? t.id)
        }
        return units.count
    }

    // MARK: - Retention

    /// Drops rows older than `days` (default 60), keeping the newest ack cursor of each agent.
    @discardableResult
    public func prune(olderThanDays days: Int = 60) -> Int {
        let cutoff = now().addingTimeInterval(-Double(days) * 86_400)
        let all = rows()
        var keepAck = Set<UUID>()
        var newestAck: [UUID: KActivity] = [:]
        for r in all where r.verb == ActivityVerb.ack {
            if let id = r.agentID, (newestAck[id]?.seq ?? 0) < r.seq { newestAck[id] = r }
        }
        for r in newestAck.values { keepAck.insert(r.id) }
        var removed = 0
        for r in all where r.at < cutoff && !keepAck.contains(r.id) {
            context.delete(r)
            removed += 1
        }
        if removed > 0 { save() }
        return removed
    }
}
