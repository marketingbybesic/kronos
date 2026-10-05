#if os(macOS)
import Testing
import Foundation
@testable import KronosCore

@MainActor
@Suite struct AgentRevertTests {

    private func rig() throws -> (AgentRig, AgentIdentity) {
        let r = try AgentRig()
        return (r, r.agent("codex", scopes: AgentScopes([.read, .propose, .writeOwn, .comment, .writeTrusted])))
    }

    @Test func tasksTheAgentCreatedTodayAreDeleted() throws {
        let (r, a) = try rig()
        let t1 = try r.taskID(r.call("create_task", ["title": "A"], as: a))
        let t2 = try r.taskID(r.call("create_task", ["title": "B"], as: a))
        let mine = r.store.createNoUndo(title: "Owner's own")
        let s = r.hub.revertToday(agentID: a.agentID, store: r.store)
        #expect(s.created == 2 && s.total == 2)
        #expect(r.store.task(t1) == nil && r.store.task(t2) == nil)
        #expect(r.store.task(mine.id) != nil, "the owner's own task is untouched")
    }

    @Test func aFieldEditIsPutBackAndTheCompletionUndone() throws {
        let (r, a) = try rig()
        let id = try r.taskID(r.call("create_task", ["title": "Original", "priority": "low", "due": "2026-10-20"], as: a))
        r.hub.rows().filter { $0.verb == ActivityVerb.created }.forEach { $0.at = r.clock.addingTimeInterval(-90_000) }   // created "yesterday"
        try r.call("update_task", ["id": id.uuidString, "title": "Renamed", "priority": "high", "due": "2026-10-25"], as: a)
        try r.call("complete_task", ["id": id.uuidString], as: a)
        let s = r.hub.revertToday(agentID: a.agentID, store: r.store)
        #expect(s.updated == 1 && s.completed == 1)
        let t = try #require(r.store.task(id))
        #expect(t.title == "Original" && t.priority == .low && t.dueDay == Day.parseISO("2026-10-20"))
        #expect(t.status == .todo)
    }

    @Test func aDeletedTaskComesBack() throws {
        let (r, a) = try rig()
        let id = try r.taskID(r.call("create_task", ["title": "Keep me"], as: a))
        r.hub.rows().forEach { $0.at = r.clock.addingTimeInterval(-90_000) }
        try r.call("delete_task", ["id": id.uuidString, "confirm": true], as: a)
        #expect(r.store.task(id) == nil)
        let s = r.hub.revertToday(agentID: a.agentID, store: r.store)
        #expect(s.deleted == 1 && r.store.task(id) != nil)
    }

    @Test func aFieldTheOwnerEditedLaterIsNotOverwritten() throws {
        let (r, a) = try rig()
        let id = try r.taskID(r.call("create_task", ["title": "Draft", "priority": "low"], as: a))
        r.hub.rows().forEach { $0.at = r.clock.addingTimeInterval(-90_000) }
        try r.call("update_task", ["id": id.uuidString, "title": "Agent title", "priority": "high"], as: a)
        r.store.updateNoUndo(id) { $0.title = "Owner title" }      // the person edits the title afterwards
        let s = r.hub.revertToday(agentID: a.agentID, store: r.store)
        let t = try #require(r.store.task(id))
        #expect(t.title == "Owner title", "the owner's edit wins")
        #expect(t.priority == .low, "the untouched field is reverted")
        #expect(s.updated == 1 && s.skipped == 1)
    }

    @Test func aSecondRunDoesNothing() throws {
        let (r, a) = try rig()
        _ = try r.taskID(r.call("create_task", ["title": "A"], as: a))
        #expect(r.hub.revertToday(agentID: a.agentID, store: r.store).total == 1)
        #expect(r.hub.revertToday(agentID: a.agentID, store: r.store).total == 0)
    }

    @Test func yesterdaysWritesAreNotRevertedAndAnotherAgentIsNotTouched() throws {
        let (r, a) = try rig()
        let other = r.agent("relay", scopes: AgentScopes([.read, .propose, .writeOwn, .writeTrusted]))
        let old = try r.taskID(r.call("create_task", ["title": "Yesterday"], as: a))
        r.hub.rows().forEach { $0.at = r.clock.addingTimeInterval(-2 * 86_400) }
        let theirs = try r.taskID(r.call("create_task", ["title": "Relay task"], as: other))
        let s = r.hub.revertToday(agentID: a.agentID, store: r.store)
        #expect(s.total == 0)
        #expect(r.store.task(old) != nil && r.store.task(theirs) != nil)
    }

    @Test func revertingIsLoggedAsOneEventAndCountsAsNoAgentWrite() throws {
        let (r, a) = try rig()
        _ = try r.taskID(r.call("create_task", ["title": "A"], as: a))
        r.hub.revertToday(agentID: a.agentID, store: r.store)
        let log = r.hub.rows().filter { $0.verb == ActivityVerb.reverted }
        #expect(log.count == 1 && log[0].actor == "me")
    }

    @Test func sevenDayWriteCountAndLastSeenFeedTheSettingsRow() throws {
        let (r, a) = try rig()
        _ = try r.taskID(r.call("create_task", ["title": "A"], as: a))
        _ = try r.taskID(r.call("create_task", ["title": "B"], as: a))
        #expect(r.hub.writeCount(agentID: a.agentID, days: 7) == 2)
    }
}

#endif
