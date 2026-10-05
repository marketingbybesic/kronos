#if os(macOS)
import Testing
import Foundation
@testable import KronosCore

@MainActor
@Suite struct MCPEventsTests {

    private func trusted(_ rig: AgentRig, _ slug: String = "codex") -> AgentIdentity {
        rig.agent(slug, scopes: AgentScopes([.read, .propose, .writeOwn, .comment, .writeTrusted]))
    }

    private func titles(_ rig: AgentRig, _ args: [String: Any]) throws -> [String] {
        var all = args
        all["view"] = "all"
        return (try rig.call("list_tasks", all).body["tasks"] as? [[String: Any]] ?? []).compactMap { $0["title"] as? String }.sorted()
    }

    // MARK: list_tasks filters

    @Test func completedSinceListsOnlyTasksClosedAtOrAfterThatTime() throws {
        let rig = try AgentRig()
        let old = rig.store.createNoUndo(title: "Old"), recent = rig.store.createNoUndo(title: "Recent")
        _ = rig.store.createNoUndo(title: "Open")
        rig.store.complete(old.id); rig.store.complete(recent.id)
        old.completedAt = Date(timeIntervalSince1970: 1_000)
        recent.completedAt = Date(timeIntervalSince1970: 5_000)
        // 1970-01-01T01:00:00Z = 3600 s: between the two.
        #expect(try titles(rig, ["completedSince": "1970-01-01T01:00:00Z"]) == ["Recent"], "implies includeDone, drops older and open tasks")
    }

    @Test func updatedSinceListsOnlyTasksChangedAtOrAfterThatTime() throws {
        let rig = try AgentRig()
        let a = rig.store.createNoUndo(title: "Stale"), b = rig.store.createNoUndo(title: "Fresh")
        a.updatedAt = Date(timeIntervalSince1970: 1_000)
        b.updatedAt = Date(timeIntervalSince1970: 9_000)
        #expect(try titles(rig, ["updatedSince": "1970-01-01T02:00:00Z"]) == ["Fresh"])   // 7200 s
    }

    @Test func aBadTimestampIsRefusedNamingTheFieldAndAPlainDayWorks() throws {
        let rig = try AgentRig()
        let bad = try rig.call("list_tasks", ["view": "all", "updatedSince": "yesterday"])
        #expect(bad.code == "INVALID_PARAMS" && (bad.body["data"] as? [String: Any])?["field"] as? String == "updatedSince")
        #expect(try !rig.call("list_tasks", ["view": "all", "updatedSince": "2026-10-01"]).isError)
        #expect(try !rig.call("list_tasks", ["view": "all", "completedSince": "2026-10-01T10:00:00.250Z"]).isError)
    }

    @Test func ownerAndReviewFiltersSeparateDinoAgentAndPending() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        _ = rig.store.createNoUndo(title: "Alex's")
        _ = try rig.call("create_task", ["title": "Agent's pending"], as: a)
        #expect(try titles(rig, ["owner": "me"]) == ["Alex's"])
        #expect(try titles(rig, ["owner": "agent"]) == ["Agent's pending"])
        #expect(try titles(rig, ["owner": "codex"]) == ["Agent's pending"])
        #expect(try titles(rig, ["owner": "any"]) == ["Agent's pending", "Alex's"])
        #expect(try titles(rig, ["review": "pending"]) == ["Agent's pending"])
        #expect(try titles(rig, ["review": "approved"]) == [])
        #expect(try rig.call("list_tasks", ["view": "all", "owner": "nobody"]).code == "NOT_FOUND")
        #expect(try rig.call("list_tasks", ["view": "all", "review": "maybe"]).code == "INVALID_PARAMS")
    }

    @Test func aCursorFromOneFilterIsRefusedForAnother() throws {
        let rig = try AgentRig()
        for i in 1...3 { _ = rig.store.createNoUndo(title: "T\(i)") }
        let page = try rig.call("list_tasks", ["view": "all", "limit": 1, "owner": "me"])
        let cursor = try #require(page.body["nextCursor"] as? String)
        #expect(try rig.call("list_tasks", ["view": "all", "limit": 1, "owner": "any", "cursor": cursor]).code == "INVALID_CURSOR")
        #expect(try !rig.call("list_tasks", ["view": "all", "limit": 1, "owner": "me", "cursor": cursor]).isError)
    }

    // MARK: events_poll

    @Test func pollWithoutAnIdentityExplainsItNeedsAnAgentToken() throws {
        let rig = try AgentRig()
        let r = try rig.call("events_poll")
        #expect(r.code == "INVALID_STATE" && r.message.contains("agent token"))
    }

    @Test func pollValidatesSinceKindsAndLimit() throws {
        let rig = try AgentRig()
        let a = trusted(rig)
        #expect(try rig.call("events_poll", ["since": "abc"], as: a).code == "INVALID_PARAMS")
        #expect(try rig.call("events_poll", ["since": "-3"], as: a).code == "INVALID_PARAMS")
        #expect(try rig.call("events_poll", ["kinds": ["task.exploded"]], as: a).code == "INVALID_PARAMS")
        #expect(try rig.call("events_poll", ["limit": 0], as: a).code == "INVALID_PARAMS")
        #expect(try rig.call("events_poll", ["waitSeconds": -1], as: a).code == "INVALID_PARAMS")
        #expect(try !rig.call("events_poll", ["since": "0", "kinds": ["task.completed"], "limit": 5, "waitSeconds": 0], as: a).isError)
    }

    @Test func pollContinuesFromTheAckedCursorAndSinceOverridesIt() throws {
        let rig = try AgentRig()
        let a = trusted(rig)
        var ids: [UUID] = []
        for i in 1...3 { ids.append(try rig.taskID(rig.call("create_task", ["title": "T\(i)"], as: a))) }
        ids.forEach { rig.store.complete($0) }
        let all = try rig.call("events_poll", [:], as: a)
        let seqs = (all.body["events"] as? [[String: Any]] ?? []).compactMap { $0["seq"] as? String }
        #expect(seqs == ["4", "5", "6"], "three creates are seq 1-3, then the three completions")
        let ack = try rig.call("events_ack", ["upTo": "5"], as: a)
        #expect(ack.body["cursor"] as? String == "5")
        let rest = try rig.call("events_poll", [:], as: a)
        #expect((rest.body["events"] as? [[String: Any]])?.compactMap { $0["seq"] as? String } == ["6"], "continues after the acked cursor")
        let replay = try rig.call("events_poll", ["since": "0"], as: a)
        #expect((replay.body["events"] as? [[String: Any]])?.count == 3, "since overrides the cursor; events are not deleted on read")
    }

    @Test func moreAndLimitPageThroughTheFeed() throws {
        let rig = try AgentRig()
        let a = trusted(rig)
        for i in 1...3 { let id = try rig.taskID(rig.call("create_task", ["title": "T\(i)"], as: a)); rig.store.complete(id) }
        let page = try rig.call("events_poll", ["limit": 2], as: a)
        #expect((page.body["events"] as? [Any])?.count == 2 && page.body["more"] as? Bool == true)
        let cursor = try #require(page.body["cursor"] as? String)
        let rest = try rig.call("events_poll", ["since": cursor], as: a)
        #expect((rest.body["events"] as? [Any])?.count == 1 && rest.body["more"] as? Bool == false)
    }

    @Test func ackNeverMovesBackAndIsClampedToTheLog() throws {
        let rig = try AgentRig()
        let a = trusted(rig)
        let id = try rig.taskID(rig.call("create_task", ["title": "T"], as: a))
        rig.store.complete(id)
        _ = try rig.call("events_poll", [:], as: a)   // seq 1 is the create, seq 2 the completion this poll reports
        #expect(try rig.call("events_ack", ["upTo": "99999"], as: a).body["cursor"] as? String == "2", "clamped to the log")
        #expect(try rig.call("events_ack", ["upTo": "1"], as: a).body["cursor"] as? String == "2", "never back")
        #expect(try rig.call("events_ack", ["upTo": "x"], as: a).code == "INVALID_PARAMS")
    }

    @Test func anotherAgentCannotSeeMyEvents() throws {
        let rig = try AgentRig()
        let a = trusted(rig, "codex"), b = trusted(rig, "relay")
        let id = try rig.taskID(rig.call("create_task", ["title": "Codex only"], as: a))
        rig.store.complete(id)
        #expect((try rig.call("events_poll", [:], as: b).body["events"] as? [Any])?.isEmpty == true)
        #expect((try rig.call("events_poll", [:], as: a).body["events"] as? [Any])?.count == 1)
    }

    // MARK: comment_task

    @Test func aCommentOnAnOwnersTaskIsStoredWithoutTouchingTheNotes() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        let t = rig.store.createNoUndo(title: "Owner task")
        let r = try rig.call("comment_task", ["id": t.id.uuidString, "text": "Sent the draft, waiting for the editor"], as: a)
        #expect(!r.isError && r.body["comments"] as? Int == 1)
        let ctx = try #require(AgentContext.decode(rig.store.task(t.id)?.contextJSON))
        #expect(ctx.comments?.first?.text == "Sent the draft, waiting for the editor" && ctx.comments?.first?.by == "agent:codex")
        #expect(rig.store.task(t.id)?.notes == "", "the owner's notes are never touched")
    }

    @Test func commentLengthIsOneToTwoHundredEighty() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        let t = rig.store.createNoUndo(title: "T")
        #expect(try !rig.call("comment_task", ["id": t.id.uuidString, "text": String(repeating: "x", count: 280)], as: a).isError)
        #expect(try rig.call("comment_task", ["id": t.id.uuidString, "text": String(repeating: "x", count: 281)], as: a).code == "INVALID_PARAMS")
        #expect(try rig.call("comment_task", ["id": t.id.uuidString, "text": "   "], as: a).code == "INVALID_PARAMS")
        #expect(try rig.call("comment_task", ["id": UUID().uuidString, "text": "hi"], as: a).code == "NOT_FOUND")
    }

    @Test func aCommentByAnotherAgentOnMyTaskIsHeardByMe() throws {
        let rig = try AgentRig()
        let mine = trusted(rig, "codex"), other = rig.agent("relay")
        let id = try rig.taskID(rig.call("create_task", ["title": "T"], as: mine))
        _ = try rig.call("comment_task", ["id": id.uuidString, "text": "Is this still open?"], as: other)
        let events = try #require(try rig.call("events_poll", [:], as: mine).body["events"] as? [[String: Any]])
        #expect(events.count == 1 && events[0]["kind"] as? String == "task.commented" && events[0]["actor"] as? String == "agent:relay")
    }

    @Test func onlyTheLastTwentyCommentsAreKept() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        let t = rig.store.createNoUndo(title: "T")
        for i in 1...25 {
            _ = try rig.call("comment_task", ["id": t.id.uuidString, "text": "c\(i)"], as: a)
            rig.advance(2)
        }
        let ctx = try #require(AgentContext.decode(rig.store.task(t.id)?.contextJSON))
        #expect(ctx.comments?.count == 20 && ctx.comments?.first?.text == "c6" && ctx.comments?.last?.text == "c25")
    }
}

#endif
