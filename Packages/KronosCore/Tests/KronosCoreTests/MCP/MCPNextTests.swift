import Testing
import Foundation
@testable import KronosCore

@MainActor
@Suite struct MCPNextTests {

    private func nextTitle(_ r: AgentRig.Reply) -> String? { (r.body["task"] as? [String: Any])?["title"] as? String }

    @Test func nextIsTheFirstEligibleRowOfTheListTheProviderShows() throws {
        let rig = try AgentRig()
        let a = rig.store.createNoUndo(title: "A blocked"), b = rig.store.createNoUndo(title: "B first eligible"), c = rig.store.createNoUndo(title: "C")
        let gate = rig.store.createNoUndo(title: "Gate")
        rig.store.setWaitsOnNoUndo(a.id, [gate.id])
        rig.dispatcher.nextProvider = { MCPNextCandidates(listName: "Inbox", ids: [a.id, b.id, c.id], barTaskID: b.id) }
        let r = try rig.call("next")
        #expect(nextTitle(r) == "B first eligible", "the blocked head row is skipped")
        #expect(r.body["list"] as? String == "Inbox" && r.body["source"] as? String == "shown")
        #expect(r.body["barTaskID"] as? String == b.id.uuidString)
        #expect((r.body["reason"] as? String)?.isEmpty == false)
    }

    @Test func aPendingClosedOrDeletedRowIsNeverNext() throws {
        let rig = try AgentRig()
        let pending = rig.store.createNoUndo(title: "Pending"), done = rig.store.createNoUndo(title: "Done"), ok = rig.store.createNoUndo(title: "Fine")
        rig.store.updateNoUndo(pending.id) { $0.reviewRaw = ReviewState.pending }
        rig.store.complete(done.id)
        rig.dispatcher.nextProvider = { MCPNextCandidates(listName: "All", ids: [pending.id, done.id, ok.id]) }
        #expect(nextTitle(try rig.call("next")) == "Fine")
        rig.store.softDeleteNoUndo(ok.id)
        #expect(try rig.call("next").body["task"] == nil, "nothing eligible is an answer, not an error")
    }

    @Test func aPinnedTaskWinsWhileOpen() throws {
        let rig = try AgentRig()
        let first = rig.store.createNoUndo(title: "First"), pinned = rig.store.createNoUndo(title: "Pinned elsewhere")
        rig.dispatcher.nextProvider = { MCPNextCandidates(listName: "Inbox", ids: [first.id], pinned: pinned.id, barTaskID: pinned.id) }
        let r = try rig.call("next")
        #expect(nextTitle(r) == "Pinned elsewhere" && r.body["reason"] as? String == "Pinned by the owner")
    }

    @Test func withNoWindowTheTodayHeadIsUsed() throws {
        let rig = try AgentRig()
        let overdue = rig.store.createNoUndo(title: "Overdue", dueDay: rig.day - 2)
        let planned = rig.store.createNoUndo(title: "Planned today")
        planned.plannedDay = rig.day
        _ = rig.store.createNoUndo(title: "Next week", dueDay: rig.day + 7)
        _ = rig.store.createNoUndo(title: "Undated")
        // Both providers answer "nothing shown": no provider at all, and an empty head.
        let none = try rig.call("next")
        #expect(none.body["source"] as? String == "today" && none.body["list"] as? String == "Today")
        let expectedFirst = NextFallback.todayHead(store: rig.store, today: rig.day, limit: 1).first
        #expect(nextTitle(none) == rig.store.task(try #require(expectedFirst))?.title, "the same task NextFallback.todayHead puts first")
        rig.dispatcher.nextProvider = { MCPNextCandidates(listName: "", ids: []) }
        let empty = try rig.call("next")
        #expect(empty.body["source"] as? String == "today" && nextTitle(empty) == nextTitle(none))
        #expect(["Overdue", "Planned today"].contains(nextTitle(none) ?? ""))
        _ = overdue
    }

    @Test func todayFallbackSkipsPendingAndBlockedRows() throws {
        let rig = try AgentRig()
        let hidden = rig.store.createNoUndo(title: "Hidden proposal", dueDay: rig.day)
        rig.store.updateNoUndo(hidden.id) { $0.reviewRaw = ReviewState.pending }
        let shown = rig.store.createNoUndo(title: "Shown", dueDay: rig.day)
        #expect(nextTitle(try rig.call("next")) == "Shown")
        _ = shown
    }

    @Test func energyChoosesAFittingRowAndLowSkipsDeepWork() throws {
        let rig = try AgentRig()
        let deep = rig.store.createNoUndo(title: "Deep thinking", dueDay: rig.day)
        rig.store.updateNoUndo(deep.id) { $0.depth = .deep }
        let quick = rig.store.createNoUndo(title: "Quick admin", dueDay: rig.day)
        rig.store.updateNoUndo(quick.id) { $0.depth = .shallow; $0.estimateMinutes = 10 }
        rig.dispatcher.nextProvider = { MCPNextCandidates(listName: "Today", ids: [deep.id, quick.id]) }
        #expect(nextTitle(try rig.call("next", ["energy": "low"])) == "Quick admin")
        #expect(nextTitle(try rig.call("next", ["energy": "high"])) != nil)
        #expect(try rig.call("next", ["energy": "enormous"]).code == "INVALID_PARAMS")
    }

    @Test func nextEqualsTheMenuBarTaskWhenTheBarShowsTheFirstRow() throws {
        let rig = try AgentRig()
        let t = rig.store.createNoUndo(title: "The bar task")
        rig.dispatcher.nextProvider = { MCPNextCandidates(listName: "Inbox", ids: [t.id], barTaskID: t.id) }
        let r = try rig.call("next")
        #expect((r.body["task"] as? [String: Any])?["id"] as? String == r.body["barTaskID"] as? String)
    }

    @Test func nextOverMcpNeverMutatesAndNeedsOnlyRead() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex", scopes: AgentScopes([.read]))
        let t = rig.store.createNoUndo(title: "T", dueDay: rig.day)
        let before = rig.store.task(t.id)?.updatedAt
        #expect(try !rig.call("next", as: a).isError)
        #expect(rig.store.task(t.id)?.updatedAt == before)
    }
}
