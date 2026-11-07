// Pure, store-free signals the app derives from activity rows it already fetched: what to show
// in the away digest, and which agent completions are worth a notification. No ModelContext
// access here, so these are trivial to unit test with any row list a caller (AgentHub, AgentRig,
// a view model) hands in.

import Foundation

public struct AgentAwaySummary: Equatable, Sendable {
    public let finished: Int
    public let proposed: Int
    public init(finished: Int, proposed: Int) { self.finished = finished; self.proposed = proposed }
    public var isEmpty: Bool { finished == 0 && proposed == 0 }
}

public enum AgentTeamSignals {

    /// finished = ActivityVerb.doneByAgent rows by an "agent:" actor (auto-approved or not —
    /// auto-approved work still counts as finished here even though it never notifies).
    ///
    /// proposed = ActivityVerb.created rows by an "agent:" actor whose payload "review" equals
    /// ReviewState.pending. `stampAgentTask` (MCPDispatcher+Agents.swift) is the only place a
    /// `created` row is ever appended, and it always writes this key as 1 (pending) or 0
    /// (trusted, created straight to ReviewState.none) — the same signal ActivitySync.swift
    /// already reads off a `created` row (`l.wasPending = AgentHub.payload(r)["review"]?.int ==
    /// ReviewState.pending`), confirmed by grep rather than guessed.
    public static func awaySummary(_ rows: [KActivity]) -> AgentAwaySummary {
        var finished = 0, proposed = 0
        for row in rows where row.actor.hasPrefix("agent:") {
            switch row.verb {
            case ActivityVerb.doneByAgent:
                finished += 1
            case ActivityVerb.created:
                if AgentHub.payload(row)["review"]?.int == ReviewState.pending { proposed += 1 }
            default:
                break
            }
        }
        return AgentAwaySummary(finished: finished, proposed: proposed)
    }

    /// `ActivityVerb.doneByAgent` rows from an "agent:" actor whose payload "auto" is not `true`
    /// (auto-approved completions never notify).
    public static func notifiable(_ rows: [KActivity]) -> [KActivity] {
        rows.filter {
            $0.verb == ActivityVerb.doneByAgent && $0.actor.hasPrefix("agent:") && AgentHub.payload($0)["auto"]?.bool != true
        }
    }

    // MARK: - Kronos v1.2 Phase 2 slice D: review that cannot rot

    /// D3: how many of `updatedAt` (one per pending/awaiting-check task row the caller already
    /// fetched from `ReviewQueue`) have not changed in at least `threshold` — the review queue
    /// rotting unseen, independent of whether the person was ever technically "away".
    public static func agingCount(updatedAt: [Date], threshold: TimeInterval, now: Date) -> Int {
        updatedAt.filter { now.timeIntervalSince($0) >= threshold }.count
    }

    /// D4: which of the Today header's three count-aware sentences applies, or none when both
    /// counts are 0. The app formats the matching localized string; this only picks which one.
    public enum ReviewRunningLine: Equatable, Sendable {
        case both(review: Int, running: Int)
        case reviewOnly(Int)
        case runningOnly(Int)
        case none
    }

    public static func reviewRunningLine(reviewCount: Int, runningCount: Int) -> ReviewRunningLine {
        switch (reviewCount > 0, runningCount > 0) {
        case (true, true): return .both(review: reviewCount, running: runningCount)
        case (true, false): return .reviewOnly(reviewCount)
        case (false, true): return .runningOnly(runningCount)
        case (false, false): return .none
        }
    }

    /// D2's ⇧A: the ids of `itemAgentIDs` (already filtered by the caller to pending/not-yet-
    /// decided items) that share `targetAgentID` — nil when there is only one (or none), so a
    /// caller never offers to "approve all" of a single item.
    public static func bulkApproveGroup(itemAgentIDs: [(id: UUID, agentID: UUID?)], targetAgentID: UUID) -> [UUID]? {
        let group = itemAgentIDs.compactMap { $0.agentID == targetAgentID ? $0.id : nil }
        return group.count > 1 ? group : nil
    }
}
