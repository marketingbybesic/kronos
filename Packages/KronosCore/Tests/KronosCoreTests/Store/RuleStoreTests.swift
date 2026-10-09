import Foundation
import Testing
@testable import KronosCore

/// House rules: the agent source, store-level delete and on/off for any `TaskStoring`, and no
/// second copy of a rule that already exists. The triage lease. Expectations by hand.
@MainActor
@Suite("RuleStoreTests")
struct RuleStoreTests {

    @Test func agentSourceIsRawThree() {
        #expect(KRuleSource.agent.rawValue == 3)
        #expect(KRuleSource(rawValue: 3) == .agent)
        let r = KRule(text: "Agent proposed rule", source: .agent)
        #expect(r.sourceRaw == 3)
        #expect(r.source == .agent)
        #expect(KRuleSource.allCases.map(\.rawValue) == [0, 1, 2, 3])
    }

    /// Delete and on/off through the protocol type the MCP dispatcher holds, no cast at the call.
    @Test func deleteAndToggleThroughTheProtocol() throws {
        let concrete = try TaskStore(inMemory: true)
        let store: any TaskStoring = concrete
        let rule = store.addRule(text: "Errands after lunch", scope: .triage, source: .manual)
        #expect(store.setRuleActive(rule.id, false))
        #expect(store.allRules(includeInactive: false).isEmpty)
        #expect(store.allRules(includeInactive: true).first?.isActive == false)
        #expect(store.setRuleActive(rule.id, false))                 // already off: still true
        #expect(store.deleteRule(rule.id))
        #expect(store.allRules(includeInactive: true).isEmpty)
        #expect(!store.deleteRule(rule.id))                          // gone
        #expect(!store.setRuleActive(UUID(), true))
        #expect(concrete.undoDepth == 1)                             // deleteRule REGISTERS UNDO (DA-018); add/toggle still don't
    }

    /// The same rule twice (case, accents, spaces ignored, same scope) is one rule; another
    /// scope is another rule. An existing rule comes back unchanged.
    @Test func addingAnExistingRuleReturnsIt() throws {
        let s = try TaskStore(inMemory: true)
        let first = s.addRule(text: "Pozivi idu poslijepodne", scope: .triage, source: .feedback)
        let again = s.addRule(text: "  POZIVI idu poslijepodne ", scope: .triage, source: .manual)
        #expect(again.id == first.id)
        #expect(again.source == .feedback)
        let other = s.addRule(text: "Pozivi idu poslijepodne", scope: .impuls, source: .manual)
        #expect(other.id != first.id)
        #expect(s.allRules(includeInactive: true).count == 2)

        // An agent's proposal waits inactive; the same proposal again changes nothing.
        let proposed = s.addRule(text: "Deep work before ten", scope: .all, source: .agent, active: false)
        #expect(proposed.inserted)
        #expect(proposed.rule.isActive == false && proposed.rule.source == .agent)
        let repeated = s.addRule(text: "deep work before ten", scope: .all, source: .agent, active: false)
        #expect(!repeated.inserted && repeated.rule.id == proposed.rule.id)
        // Proposing what the person already has active leaves their rule on.
        let owned = s.addRule(text: "Pozivi idu poslijepodne", scope: .triage, source: .agent, active: false)
        #expect(!owned.inserted && owned.rule.isActive)
    }

    // MARK: Triage lease

    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func leaseIsExclusiveUntilItExpires() throws {
        let s = try TaskStore(inMemory: true)
        let t = s.create(title: "Needs triage")
        let stamp = t.updatedAt
        #expect(s.claimTriageLease(t.id, owner: "mac", now: Self.t0))
        #expect(s.triageLeaseHolder(t.id, now: Self.t0) == "mac")
        #expect(!s.claimTriageLease(t.id, owner: "iphone", now: Self.t0.addingTimeInterval(599)))
        #expect(s.claimTriageLease(t.id, owner: "mac", now: Self.t0.addingTimeInterval(300)))   // renew
        #expect(s.task(t.id)?.triageLeaseUntil == Self.t0.addingTimeInterval(900))
        #expect(!s.claimTriageLease(t.id, owner: "iphone", now: Self.t0.addingTimeInterval(899)))
        #expect(s.claimTriageLease(t.id, owner: "iphone", now: Self.t0.addingTimeInterval(900)))  // expired
        #expect(s.triageLeaseHolder(t.id, now: Self.t0.addingTimeInterval(901)) == "iphone")
        s.releaseTriageLease(t.id, owner: "mac")                                               // not the holder
        #expect(s.task(t.id)?.triageLeaseOwner == "iphone")
        s.releaseTriageLease(t.id, owner: "iphone")
        #expect(s.triageLeaseHolder(t.id, now: Self.t0.addingTimeInterval(902)) == nil)
        #expect(s.task(t.id)?.triageLeaseUntil == nil)
        #expect(!s.claimTriageLease(t.id, owner: "", now: Self.t0))
        #expect(!s.claimTriageLease(UUID(), owner: "mac", now: Self.t0))
        #expect(s.task(t.id)?.updatedAt == stamp)       // a claim is not an edit
        #expect(s.undoDepth == 1)                         // only the create
        #expect(TriageLease.duration == 600)
    }
}
