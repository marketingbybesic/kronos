#if os(macOS)
import Testing
import Foundation
@testable import KronosCore

/// What the person does in the app becomes events: exactly one per change, none on a repeat run.
@MainActor
@Suite struct ActivitySyncTests {

    private func trustedRig() throws -> (AgentRig, AgentIdentity) {
        let rig = try AgentRig()
        return (rig, rig.agent("codex", scopes: AgentScopes([.read, .propose, .writeOwn, .comment, .writeTrusted])))
    }

    private func makeTask(_ rig: AgentRig, _ a: AgentIdentity, _ title: String = "Reply to the editor") throws -> UUID {
        try rig.taskID(rig.call("create_task", ["title": title], as: a))
    }

    private func verbs(_ rig: AgentRig) -> [String] {
        rig.hub.rows().filter { $0.verb != ActivityVerb.created && $0.verb != ActivityVerb.updated }.map(\.verb)
    }

    @Test func completingATaskInTheAppProducesOneCompletedEvent() throws {
        let (rig, a) = try trustedRig()
        let id = try makeTask(rig, a)
        #expect(rig.hub.sync(store: rig.store) == 0, "nothing changed yet")
        rig.store.complete(id)
        #expect(rig.hub.sync(store: rig.store) == 1)
        #expect(rig.hub.sync(store: rig.store) == 0, "a second run adds nothing")
        let e = try #require(rig.hub.events(for: a, since: 0).events.first)
        #expect(e.verb == ActivityVerb.completed && e.actor == "me" && e.taskID == id)
        #expect(AgentHub.payload(e)["title"]?.string == "Reply to the editor")
    }

    @Test func reopeningAfterCompletionIsReportedOnceAndCompletingAgainAgain() throws {
        let (rig, a) = try trustedRig()
        let id = try makeTask(rig, a)
        rig.store.complete(id); rig.hub.sync(store: rig.store)
        rig.store.reopen(id); rig.hub.sync(store: rig.store)
        rig.hub.sync(store: rig.store)
        rig.store.complete(id); rig.hub.sync(store: rig.store)
        #expect(verbs(rig) == [ActivityVerb.completed, ActivityVerb.reopened, ActivityVerb.completed])
    }

    @Test func aTaskTheOwnerDeletesIsReportedAsDeleted() throws {
        let (rig, a) = try trustedRig()
        let id = try makeTask(rig, a)
        rig.store.softDelete(id)
        #expect(rig.hub.sync(store: rig.store) == 1)
        #expect(rig.hub.sync(store: rig.store) == 0)
        #expect(verbs(rig) == [ActivityVerb.deleted])
    }

    @Test func aTaskThatIsPurgedForGoodIsReportedOnce() throws {
        let (rig, a) = try trustedRig()
        let id = try makeTask(rig, a)
        rig.store.softDelete(id); rig.hub.sync(store: rig.store)
        rig.store.purgeDeletedOlderThan(days: 0, now: Date().addingTimeInterval(86_400))
        #expect(rig.store.taskIncludingDeleted(id) == nil)
        #expect(rig.hub.sync(store: rig.store) == 0, "already reported as deleted")
    }

    @Test func approvingAndRejectingProposalsReportDecisionEditsAndReason() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        let keep = try rig.taskID(rig.call("create_task", ["title": "Keep"], as: a))
        let drop = try rig.taskID(rig.call("create_task", ["title": "Drop"], as: a))
        #expect(AgentReview.approve(keep, editedFields: ["due"], store: rig.store))
        #expect(AgentReview.reject(drop, reason: "duplicate", store: rig.store))
        #expect(rig.hub.sync(store: rig.store) == 2)
        let events = rig.hub.events(for: a, since: 0).events
        let approved = try #require(events.first { $0.verb == ActivityVerb.approved })
        let rejected = try #require(events.first { $0.verb == ActivityVerb.rejected })
        #expect(AgentHub.payload(approved)["decision"]?.string == "edit")
        #expect(AgentHub.payload(approved)["editedFields"]?.array?.compactMap(\.string) == ["due"])
        #expect(AgentHub.payload(rejected)["reason"]?.string == "duplicate")
        #expect(rig.hub.sync(store: rig.store) == 0)
    }

    @Test func aTaskGivenToAnAgentByTheOwnerIsReportedAsAssigned() throws {
        let (rig, a) = try trustedRig()
        let t = rig.store.createNoUndo(title: "Draft the reply")
        rig.store.updateNoUndo(t.id) { $0.agentID = a.agentID; $0.assigneeRaw = 1 }
        #expect(rig.hub.sync(store: rig.store) == 1)
        #expect(rig.hub.events(for: a, since: 0).events.first?.verb == ActivityVerb.assigned)
        #expect(rig.hub.sync(store: rig.store) == 0)
    }

    @Test func anAgentsOwnWriteIsNeverReportedBackToItsAuthor() throws {
        let (rig, a) = try trustedRig()
        let id = try makeTask(rig, a)
        try rig.call("complete_task", ["id": id.uuidString], as: a)          // the agent closes its own task
        try rig.call("update_task", ["id": id.uuidString, "status": "todo"], as: a)   // and reopens it
        rig.hub.sync(store: rig.store)
        #expect(rig.hub.events(for: a, since: 0).events.isEmpty)
    }

    @Test func ownerTasksWithoutAnAgentAreIgnored() throws {
        let (rig, _) = try trustedRig()
        let t = rig.store.createNoUndo(title: "Mine")
        rig.store.complete(t.id)
        #expect(rig.hub.sync(store: rig.store) == 0)
    }

    @Test func aSpentUpdateProposalIsReportedAsApprovedNotDeleted() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        let target = rig.store.createNoUndo(title: "Alex's task")
        let r = try rig.call("propose_update", ["id": target.id.uuidString, "patch": ["priority": "high"]], as: a)
        let shadow = try rig.uuid(r.str("proposalTaskID"))
        #expect(AgentReview.approve(shadow, store: rig.store))
        rig.hub.sync(store: rig.store)
        #expect(verbs(rig) == [ActivityVerb.approved])
        #expect(rig.store.task(target.id)?.priority == .high)
    }
}

#endif
