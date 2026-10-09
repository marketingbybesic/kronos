// Pure, store-free signals the app derives from activity rows it already fetched: what to show
// in the away digest, who is working on a task right now, and which agent completions are worth
// a notification. No ModelContext access here, so these are trivial to unit test with any row
// list a caller (AgentHub, AgentRig, a view model) hands in.

import Foundation

public struct AgentAwaySummary: Equatable, Sendable {
    public let finished: Int
    public let proposed: Int
    public init(finished: Int, proposed: Int) { self.finished = finished; self.proposed = proposed }
    public var isEmpty: Bool { finished == 0 && proposed == 0 }
}

public struct AgentClaim: Equatable, Sendable {
    public let slug: String
    public let at: Date
    public init(slug: String, at: Date) { self.slug = slug; self.at = at }
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

    /// Walks `rows` in seq order (the order `AgentHub.rows(...)` returns). For an
    /// `ActivityVerb.updated` row with a taskID whose payload `after["status"]` is present: a
    /// status of `KStatus.inProgress.rawValue` from an "agent:" actor claims the task; any other
    /// status value clears an existing claim, whoever changed it (the claim is display-only and
    /// dies the moment the task leaves in-progress, so clearing does not care who moved it away).
    /// An in-progress row from a non-agent actor is ignored outright — it neither claims nor
    /// clears, so an agent's existing claim stands until a later row actually moves the status
    /// elsewhere. Rows with no taskID or no payload "after status" are skipped.
    public static func workClaims(_ rows: [KActivity]) -> [UUID: AgentClaim] {
        var claims: [UUID: AgentClaim] = [:]
        for row in rows {
            guard row.verb == ActivityVerb.updated, let taskID = row.taskID,
                  let status = AgentHub.payload(row)["after"]?.object?["status"]?.int else { continue }
            if status == KStatus.inProgress.rawValue {
                if row.actor.hasPrefix("agent:") {
                    claims[taskID] = AgentClaim(slug: String(row.actor.dropFirst("agent:".count)), at: row.at)
                }
            } else {
                claims[taskID] = nil
            }
        }
        return claims
    }

    /// `ActivityVerb.doneByAgent` rows from an "agent:" actor whose payload "auto" is not `true`
    /// (auto-approved completions never notify).
    public static func notifiable(_ rows: [KActivity]) -> [KActivity] {
        rows.filter {
            $0.verb == ActivityVerb.doneByAgent && $0.actor.hasPrefix("agent:") && AgentHub.payload($0)["auto"]?.bool != true
        }
    }
}
