import Testing
import Foundation
@testable import KronosCore

@MainActor
@Suite struct MCPRulesOrdoTests {

    // MARK: rules_add / rules_delete through the store API

    @Test func anAgentRuleIsStoredInactiveWithTheAgentSource() throws {
        let rig = try AgentRig()
        let r = try rig.call("rules_add", ["text": "Never schedule on Sundays"])
        #expect(!r.isError && r.body["created"] as? Bool == true)
        let rule = try #require(rig.store.allRules(includeInactive: true).first)
        #expect(rule.isActive == false && rule.sourceRaw == KRuleSource.agent.rawValue)
        #expect((r.body["rule"] as? [String: Any])?["source"] as? String == "agent")
    }

    @Test func anEqualOwnerRuleIsReturnedUnchangedNotDeactivatedOrRelabelled() throws {
        let rig = try AgentRig()
        let own = rig.store.addRule(text: "Never schedule on Sundays", scope: .all, source: .manual, active: true).rule
        let r = try rig.call("rules_add", ["text": "  never schedule on sundays "])
        #expect(!r.isError && r.body["created"] as? Bool == false)
        #expect(own.isActive == true && own.sourceRaw == KRuleSource.manual.rawValue, "the owner's rule is untouched")
        #expect(rig.store.allRules(includeInactive: true).count == 1)
    }

    @Test func deleteGoesThroughTheStoreAndUnknownIsNotFound() throws {
        let rig = try AgentRig()
        let added = try rig.call("rules_add", ["text": "No meetings before noon"])
        let id = try #require((added.body["rule"] as? [String: Any])?["id"] as? String)
        #expect(try !rig.call("rules_delete", ["id": id]).isError)
        #expect(rig.store.allRules(includeInactive: true).isEmpty)
        #expect(try rig.call("rules_delete", ["id": id]).code == "NOT_FOUND")
    }

    // MARK: ordo_set moves few rows

    private func queue(_ rig: AgentRig, _ n: Int) -> [KTask] {
        let tasks = (1...n).map { rig.store.createNoUndo(title: "T\($0)") }
        for (i, t) in tasks.enumerated() { rig.store.updateNoUndo(t.id) { $0.ordoIndex = Double(i + 1) * 1024 } }
        return tasks
    }

    private func indices(_ tasks: [KTask]) -> [Double?] { tasks.map(\.ordoIndex) }

    @Test func movingOneTaskToTheFrontRewritesOnlyThatRow() throws {
        let rig = try AgentRig()
        let t = queue(rig, 6)
        let before = indices(t)
        let order = [t[5], t[0], t[1], t[2], t[3], t[4]].map(\.id.uuidString)
        #expect(try !rig.call("ordo_set", ["order": order]).isError)
        let after = indices(t)
        let changed = zip(before, after).filter { $0 != $1 }.count
        #expect(changed == 1, "only the moved row got a new index, \(changed) changed")
        let sorted = t.sorted { ($0.ordoIndex ?? 0) < ($1.ordoIndex ?? 0) }.map(\.title)
        #expect(sorted == ["T6", "T1", "T2", "T3", "T4", "T5"])
    }

    @Test func movingOneTaskToTheEndOrTheMiddleChangesAtMostThreeRows() throws {
        let rig = try AgentRig()
        let t = queue(rig, 8)
        let before = indices(t)
        let order = [t[1], t[2], t[3], t[0], t[4], t[5], t[6], t[7]].map(\.id.uuidString)   // T1 moved to the middle
        #expect(try !rig.call("ordo_set", ["order": order]).isError)
        let changed = zip(before, indices(t)).filter { $0 != $1 }.count
        #expect(changed <= 3, "\(changed) rows rewritten")
        let sorted = t.sorted { ($0.ordoIndex ?? 0) < ($1.ordoIndex ?? 0) }.map(\.title)
        #expect(sorted == ["T2", "T3", "T4", "T1", "T5", "T6", "T7", "T8"])
    }

    @Test func theSameOrderWritesNothing() throws {
        let rig = try AgentRig()
        let t = queue(rig, 4)
        let before = indices(t)
        #expect(try !rig.call("ordo_set", ["order": t.map(\.id.uuidString)]).isError)
        #expect(indices(t) == before)
    }

    @Test func aTaskNewToTheQueueIsPlacedWhereTheOrderPutsIt() throws {
        let rig = try AgentRig()
        let t = queue(rig, 3)
        let fresh = rig.store.createNoUndo(title: "New")
        let order = [t[0], fresh, t[1], t[2]].map(\.id.uuidString)
        #expect(try !rig.call("ordo_set", ["order": order]).isError)
        let all = [t[0], fresh, t[1], t[2]]
        #expect(all.compactMap(\.ordoIndex) == all.compactMap(\.ordoIndex).sorted() && all.allSatisfy { $0.ordoIndex != nil })
        #expect(fresh.ordoIndex! > t[0].ordoIndex! && fresh.ordoIndex! < t[1].ordoIndex!)
    }

    @Test func aFullyReversedQueueStillEndsInTheRequestedOrder() throws {
        let rig = try AgentRig()
        let t = queue(rig, 5)
        #expect(try !rig.call("ordo_set", ["order": t.reversed().map(\.id.uuidString)]).isError)
        let sorted = t.sorted { ($0.ordoIndex ?? 0) < ($1.ordoIndex ?? 0) }.map(\.title)
        #expect(sorted == ["T5", "T4", "T3", "T2", "T1"])
    }
}
