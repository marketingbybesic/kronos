// House rules, from the stored rows to what the router renders into a prompt, plus the two
// edits the Settings list needs (switch on or off, delete).
//
// Rules are edited in their own list, never with Cmd-Z (see `TaskStoring.addRule`), so neither
// edit registers an undo step.

import Foundation

public extension HouseRule {
    /// A `Sendable` copy of the fields the prompt renderer reads.
    init(_ rule: KRule) {
        self.init(text: rule.text, scope: rule.scope, isActive: rule.isActive, createdAt: rule.createdAt)
    }
}

public extension KRule {
    /// True for a rule an agent proposed over MCP (stored switched off until the person turns it on).
    var isFromAgent: Bool { source == .agent }
}

@MainActor
public extension TaskStore {

    /// Active rules as the router wants them, oldest first.
    func activeHouseRules() -> [HouseRule] {
        activeRules().map(HouseRule.init)
    }

    /// A rule as an agent proposes it: marked as the agent's and switched off until the person
    /// turns it on (the same state MCP `rules_add` leaves).
    @discardableResult
    func addAgentRule(text: String, scope: KRuleScope) -> KRule {
        addRule(text: text, scope: scope, source: .agent, active: false).rule
    }
}
