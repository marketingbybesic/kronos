#if os(macOS)
import Testing
import Foundation
@testable import KronosCore

@MainActor
@Suite struct EventDigestTests {

    private let at = Date(timeIntervalSince1970: 1_790_000_000)   // 2026-09-21 UTC

    private func ev(_ seq: Int, _ kind: String, _ title: String, note: String? = nil, reason: String? = nil,
                    edited: [String] = [], outcome: String? = nil) -> DigestEvent {
        DigestEvent(seq: seq, kind: kind, at: at, actor: "me", title: title, note: note, outcome: outcome,
                    editedFields: edited, reason: reason)
    }

    @Test func noEventsPrintNothing() {
        #expect(EventDigest.markdown([]) == nil)
    }

    @Test func twoFinishedTasksReadDinoFinishedTwoOfYourTasks() throws {
        let text = try #require(EventDigest.markdown([
            ev(1, ActivityVerb.completed, "Reply to the editor", note: "Poslano, naslov bez izmjena"),
            ev(2, ActivityVerb.completed, "Send quote"),
        ]))
        let expected = """
        Kronos: since last time, 2 updates from Alex.

        Alex finished 2 of your tasks:
        - Reply to the editor. Note: Poslano, naslov bez izmjena
        - Send quote
        """
        #expect(text == expected)
    }

    @Test func aMixedFeedGroupsByKindInAFixedOrder() throws {
        let text = try #require(EventDigest.markdown([
            ev(1, ActivityVerb.rejected, "Plan B", reason: "duplicate"),
            ev(2, ActivityVerb.approved, "Plan A", edited: ["due", "project"]),
            ev(3, ActivityVerb.completed, "Task C", outcome: "canceled"),
            ev(4, ActivityVerb.reopened, "Task D", note: "missing the link"),
            ev(5, ActivityVerb.deleted, "Task E"),
            ev(6, ActivityVerb.assigned, "Task F"),
            ev(7, ActivityVerb.commented, "Task G", note: "which version?"),
        ]))
        let expected = """
        Kronos: since last time, 7 updates from Alex.

        Alex finished 1 of your tasks:
        - Task C (canceled)

        Alex approved 1 proposal:
        - Plan A (edited: due, project)

        Alex rejected 1 proposal:
        - Plan B (reason: duplicate)

        Alex reopened 1 task:
        - Task D. Note: missing the link

        Alex deleted 1 of your tasks:
        - Task E

        Alex gave you 1 task:
        - Task F

        1 new comment:
        - Task G: which version?
        """
        #expect(text == expected)
    }

    @Test func theMemoryBlockIsFrontmatterMarkdownPlusJSON() {
        let id = UUID(uuidString: "ABCDEF12-0000-0000-0000-000000000000")!
        let m = EventDigest.memory(for: DigestEvent(seq: 4, kind: ActivityVerb.completed, at: at, actor: "me",
                                                    title: "Reply to the editor", taskID: id, note: "Poslano"))
        let expected = "---\nname: kronos-abcdef12\ndescription: Alex finished \"Reply to the editor\"\ntype: reference\n---\n"
            + "Alex finished \"Reply to the editor\" on 2026-09-21. Note: Poslano\n"
        #expect(m.markdown == expected)
        #expect(m.json["kind"]?.string == ActivityVerb.completed)
        #expect(m.json["taskID"]?.string == id.uuidString)
        #expect(m.json["note"]?.string == "Poslano")
    }

    @Test func endToEndAnAgentCreatesTheOwnerCompletesAndThePollAndDigestSayFinished() throws {
        let rig = try AgentRig()
        let a = rig.agent("claude-code", scopes: AgentScopes([.read, .propose, .writeOwn, .comment, .writeTrusted]))
        let id = try rig.taskID(rig.call("create_task", ["title": "Reply to the editor"], as: a))
        rig.store.complete(id)

        let poll = try rig.call("events_poll", [:], as: a)
        #expect(!poll.isError)
        let events = try #require(poll.body["events"] as? [[String: Any]])
        #expect(events.count == 1)
        let first = events[0]
        #expect(first["kind"] as? String == "task.completed" && first["actor"] as? String == "me")
        let task = try #require(first["task"] as? [String: Any])
        #expect(task["title"] as? String == "Reply to the editor")
        let memory = try #require(first["memory"] as? [String: Any])
        #expect((memory["markdown"] as? String)?.contains("Alex finished \"Reply to the editor\"") == true)
        #expect(poll.body["cursor"] as? String == "2", "seq 1 is the agent's own create, seq 2 the owner's completion")

        let rows = rig.hub.events(for: a, since: 0).events
        let digest = try #require(EventDigest.markdown(rows.map { DigestEvent(row: $0, title: rig.store.task($0.taskID ?? UUID())?.title) }))
        #expect(digest.contains("Alex finished 1 of your tasks"))
        #expect(digest.contains("- Reply to the editor"))
        // Acked: the next digest has nothing to say.
        let last = try #require(rows.last).seq
        _ = try rig.call("events_ack", ["upTo": String(last)], as: a)
        let again = try rig.call("events_poll", [:], as: a)
        #expect((again.body["events"] as? [Any])?.isEmpty == true)
    }
}

#endif
