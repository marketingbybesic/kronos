// Agent rights. An agent is one of the programs the person lets work through MCP (Claude Code,
// Codex, Relay, ...). Each holds a set of scopes; the dispatcher refuses what a scope does not
// cover. Scopes are for attribution, limits and revocation, not for defending against malware
// on the same Mac (any process running as the person can open the store file directly).

import Foundation

public enum AgentScope: String, CaseIterable, Sendable {
    /// Every read tool: list, get, ordo_get, rules_list, events_poll, next, whoami.
    case read
    /// create_task, propose_tasks, propose_update, rules_add: everything lands pending review.
    case propose
    /// Update, complete, delete and restore tasks the agent created or was assigned.
    case writeOwn = "write.own"
    /// Created tasks skip review. Off by default, set per agent in Settings only.
    case writeTrusted = "write.trusted"
    /// comment_task on any task.
    case comment
    /// Reserved: reordering foreign tasks is refused outright for now.
    case ordoPropose = "ordo.propose"
    /// rules_add (a rule always starts inactive); `propose` grants it too.
    case rulesPropose = "rules.propose"
    /// Full control. Off by default, set per agent in Settings only: update, complete, reopen and
    /// reorder ANY task, edit any subtask, and create or change projects, areas and labels.
    /// It never covers deleting a task or a house rule, and never the review verdict (the person's
    /// Accept / Reject): those stay refused whatever the agent holds.
    case writeAll = "write.all"
}

public struct AgentScopes: Equatable, Sendable {
    public var set: Set<AgentScope>

    public init(_ set: Set<AgentScope>) { self.set = set }

    /// A new agent's rights.
    public static let standard = AgentScopes([.read, .propose, .writeOwn, .comment])
    /// What the shared legacy token gets: it cannot be told apart from another client.
    public static let legacy = AgentScopes([.read, .propose])
    /// The person's own process (no agent identity): nothing is refused.
    public static let all = AgentScopes(Set(AgentScope.allCases))

    public func has(_ scope: AgentScope) -> Bool { set.contains(scope) }

    /// Comma-joined in declaration order, the form stored in `KAgent.scopesRaw`.
    public var csv: String {
        AgentScope.allCases.filter { set.contains($0) }.map(\.rawValue).joined(separator: ",")
    }

    /// Unknown names are ignored, so a scope added later never breaks an old row.
    public init(csv: String) {
        self.set = Set(csv.split(separator: ",").compactMap { AgentScope(rawValue: $0.trimmingCharacters(in: .whitespaces)) })
    }
}

/// Who is calling, as the dispatcher sees it. `nil` identity = the person's own process.
public struct AgentIdentity: Equatable, Sendable {
    public var agentID: UUID
    public var slug: String
    public var displayName: String
    public var scopes: AgentScopes
    /// True for a caller that presented the shared legacy token.
    public var isLegacy: Bool
    public var rateLimitPerMinute: Int
    public var dailyCreateCap: Int
    public var maxPendingProposals: Int

    public init(agentID: UUID, slug: String, displayName: String, scopes: AgentScopes, isLegacy: Bool = false,
                rateLimitPerMinute: Int = 60, dailyCreateCap: Int = 40, maxPendingProposals: Int = 15) {
        self.agentID = agentID
        self.slug = slug
        self.displayName = displayName
        self.scopes = scopes
        self.isLegacy = isLegacy
        self.rateLimitPerMinute = rateLimitPerMinute
        self.dailyCreateCap = dailyCreateCap
        self.maxPendingProposals = maxPendingProposals
    }

    /// Actor string written to the activity log.
    public var actor: String { "agent:\(slug)" }
}
