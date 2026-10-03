import Testing
import Foundation
@testable import KronosCore

/// The rule operations reached through `any TaskStoring` (how the MCP dispatcher holds the store)
/// must land on the store's own implementation. A forwarder that resolves back to itself never
/// returns: the process dies of stack exhaustion, so a regression fails this suite loudly.
@MainActor
@Suite struct RuleForwardingTests {

    @Test func addRuleThroughTheProtocolInsertsOnceAndKeepsTheRequestedState() throws {
        let store = try TaskStore(inMemory: true)
        let any: any TaskStoring = store
        let first = try #require(any.addRule(text: "Calls before noon", scope: .all, source: .agent, active: false))
        #expect(first.inserted == true)
        #expect(first.rule.isActive == false)
        #expect(first.rule.source == .agent)
        let again = try #require(any.addRule(text: "  calls BEFORE noon ", scope: .all, source: .manual, active: true))
        #expect(again.inserted == false, "an equal rule is returned, not added twice")
        #expect(again.rule.id == first.rule.id)
        #expect(again.rule.isActive == false, "the existing rule stays as it was")
        #expect(store.allRules(includeInactive: true).count == 1)
    }

    @Test func setRuleActiveAndDeleteRuleThroughTheProtocolReachTheStore() throws {
        let store = try TaskStore(inMemory: true)
        let any: any TaskStoring = store
        let rule = try #require(any.addRule(text: "Admin after lunch", scope: .ordo, source: .manual, active: true)).rule
        #expect(any.setRuleActive(rule.id, false) == true)
        #expect(store.allRules(includeInactive: false).isEmpty)
        #expect(store.allRules(includeInactive: true).first?.isActive == false)
        #expect(any.setRuleActive(UUID(), true) == false, "an unknown id is not found")
        #expect(any.deleteRule(rule.id) == true)
        #expect(store.allRules(includeInactive: true).isEmpty)
        #expect(any.deleteRule(rule.id) == false, "a second delete finds nothing")
    }

    @Test func theConcreteStoreAnswersTheSameWay() throws {
        let store = try TaskStore(inMemory: true)
        let added = store.addRule(text: "One thing at a time", scope: .all, source: .manual, active: true)
        #expect(added.inserted == true && added.rule.isActive == true)
        #expect(store.addRule(text: "one thing at a time", scope: .all, source: .agent, active: false).inserted == false)
        #expect(store.setRuleActive(added.rule.id, true) == true, "already in that state: true, no write")
        #expect(store.deleteRule(added.rule.id) == true)
    }
}
