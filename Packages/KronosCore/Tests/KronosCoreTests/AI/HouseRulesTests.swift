#if os(macOS)
import Testing
import Foundation
@testable import KronosCore

private let validTriageReply = """
{"project":null,"priority":2,"due":null,"depth":"shallow","estimateMinutes":15,
 "energyKind":"admin","firstMove":"Open the invoice folder and find September.","labels":[],
 "rationale":"One document and one email, no preparation needed.","effort":2,"reason":null,"dread":null}
"""

/// What the router writes into the system prompt for the rules it was given.
struct HouseRulesInPromptTests {

    private func triageSystemPrompt(rules: [HouseRule]) async throws -> String {
        let client = FixtureAIClient(modelID: "claude-sonnet-5", script: [.content(validTriageReply)])
        let router = AIRouter(mode: .allowAny, candidates: [AIRoutedCandidate(client: client)], houseRules: rules)
        _ = try await router.triage(title: "Send the invoice", notes: "", projectNames: [], labelNames: [],
                                    today: 20_000, lockedFields: [], context: .empty)
        let log = await client.callLog
        #expect(log.count == 1)
        return log[0].messages.first { $0.role == "system" }?.content ?? ""
    }

    private func rule(_ text: String, scope: KRuleScope = .all, active: Bool = true) -> HouseRule {
        HouseRule(text: text, scope: scope, isActive: active, createdAt: Date(timeIntervalSince1970: 1_000))
    }

    @Test func anActiveRuleReachesTheTriagePrompt() async throws {
        let prompt = try await triageSystemPrompt(rules: [rule("Anything about Acme is shallow work.")])
        #expect(prompt.contains("Anything about Acme is shallow work."))
        #expect(prompt.contains("House rules (the user's corrections"))
    }

    @Test func anInactiveRuleDoesNotReachTheTriagePrompt() async throws {
        let prompt = try await triageSystemPrompt(rules: [rule("Anything about Acme is shallow work.", active: false)])
        #expect(!prompt.contains("Anything about Acme is shallow work."))
        #expect(prompt.contains("House rules: none."))
    }

    @Test func aRuleScopedToAnotherFeatureDoesNotReachTheTriagePrompt() async throws {
        let prompt = try await triageSystemPrompt(rules: [rule("Globex tasks go first.", scope: .ordo)])
        #expect(!prompt.contains("Globex tasks go first."))
    }

    @Test func aTriageScopedRuleReachesTheTriagePrompt() async throws {
        let prompt = try await triageSystemPrompt(rules: [rule("Calls are people work.", scope: .triage)])
        #expect(prompt.contains("Calls are people work."))
    }
}

/// The stored rows, the switch and the delete that the Settings list uses.
@MainActor
struct HouseRuleStoreTests {

    private func makeStore() throws -> TaskStore { try TaskStore(inMemory: true) }

    @Test func aRuleAnAgentAddedStartsOutOfThePromptAndSwitchesOn() throws {
        let store = try makeStore()
        let rule = store.addRule(text: "Invoices are admin work.", scope: .triage, source: .manual)
        rule.sourceRaw = KRule.agentSourceRaw
        rule.isActive = false
        store.saveContext()

        #expect(store.activeHouseRules().isEmpty)
        #expect(rule.isFromAgent)

        #expect(store.setRuleActive(rule.id, true))
        #expect(store.activeHouseRules().map(\.text) == ["Invoices are admin work."])
        #expect(store.activeHouseRules().first?.scope == .triage)

        #expect(store.setRuleActive(rule.id, false))
        #expect(store.activeHouseRules().isEmpty)
    }

    @Test func switchingToTheStateItAlreadyHasWritesNothing() throws {
        let store = try makeStore()
        let rule = store.addRule(text: "Invoices are admin work.", scope: .all, source: .manual)
        let stamp = rule.updatedAt
        #expect(store.setRuleActive(rule.id, true))   // already on: reported as done, nothing written
        #expect(rule.updatedAt == stamp)
        #expect(!store.setRuleActive(UUID(), false))
    }

    @Test func deleteRemovesTheRuleAndOnlyThatRule() throws {
        let store = try makeStore()
        let keep = store.addRule(text: "Calls are people work.", scope: .all, source: .manual)
        let drop = store.addRule(text: "Invoices are admin work.", scope: .all, source: .manual)
        #expect(store.deleteRule(drop.id))
        #expect(store.allRules(includeInactive: true).map(\.id) == [keep.id])
        #expect(!store.deleteRule(drop.id))
    }

    @Test func aHandWrittenRuleIsNotMarkedAsFromAnAgent() throws {
        let store = try makeStore()
        let rule = store.addRule(text: "Calls are people work.", scope: .all, source: .manual)
        #expect(!rule.isFromAgent)
    }

    @Test func theRouterTakesTheRulesTheStoreHoldsAfterASwitch() async throws {
        let store = try makeStore()
        let rule = store.addRule(text: "Anything about Acme is shallow work.", scope: .all, source: .manual)
        rule.isActive = false
        store.saveContext()
        let client = FixtureAIClient(modelID: "claude-sonnet-5",
                                     script: [.content(validTriageReply), .content(validTriageReply)])
        let base = AIRouter(mode: .allowAny, candidates: [AIRoutedCandidate(client: client)])

        let off = base.withHouseRules(store.activeHouseRules())
        _ = try await off.triage(title: "Send the invoice", notes: "", projectNames: [], labelNames: [],
                                 today: 20_000, lockedFields: [], context: .empty)
        store.setRuleActive(rule.id, true)
        let on = base.withHouseRules(store.activeHouseRules())
        _ = try await on.triage(title: "Send the invoice", notes: "", projectNames: [], labelNames: [],
                                today: 20_000, lockedFields: [], context: .empty)

        let log = await client.callLog
        let systems = log.map { $0.messages.first { $0.role == "system" }?.content ?? "" }
        #expect(systems.count == 2)
        #expect(!systems[0].contains("Anything about Acme is shallow work."))
        #expect(systems[1].contains("Anything about Acme is shallow work."))
    }
}

/// The router is rebuilt only when one of its inputs changed.
struct RouterConfigSignatureTests {

    private func signature(mode: AIMode = .allowAny, provider: String = "ghostCLI",
                           url: String = "https://example.test/v1", model: String = "claude-sonnet-5",
                           rules: [HouseRule] = []) -> RouterConfigSignature {
        RouterConfigSignature(mode: mode, provider: provider, baseURL: url, modelID: model, rules: rules)
    }

    private func rule(_ text: String, active: Bool) -> HouseRule {
        HouseRule(text: text, scope: .all, isActive: active, createdAt: Date(timeIntervalSince1970: 5))
    }

    @Test func theSameInputsAreEqual() {
        #expect(signature() == signature())
    }

    @Test func eachAIKeyChangesTheSignature() {
        let base = signature()
        #expect(base != signature(mode: .privateOnly))
        #expect(base != signature(provider: "openRouter"))
        #expect(base != signature(url: "https://other.test/v1"))
        #expect(base != signature(model: "gpt-6-astra"))
    }

    @Test func anActiveRuleChangesItAndAnInactiveOneDoesNot() {
        let base = signature()
        #expect(base != signature(rules: [rule("Calls are people work.", active: true)]))
        #expect(base == signature(rules: [rule("Calls are people work.", active: false)]))
    }
}

#endif
