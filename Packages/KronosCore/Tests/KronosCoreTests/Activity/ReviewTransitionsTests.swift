#if os(macOS)
import Testing
import Foundation
@testable import KronosCore

@MainActor
@Suite struct ReviewTransitionsTests {

    private func pending(_ rig: AgentRig, _ a: AgentIdentity, _ title: String = "Proposal") throws -> UUID {
        try rig.taskID(rig.call("create_task", ["title": title], as: a))
    }

    @Test func approveMakesAPendingTaskOrdinaryAndRecordsTheDecision() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        let id = try pending(rig, a)
        #expect(AgentReview.approve(id, store: rig.store))
        let t = try #require(rig.store.task(id))
        #expect(t.reviewRaw == ReviewState.approved && t.deletedAt == nil)
        let r = try #require(AgentTaskResult.decode(t.resultJSON))
        #expect(r.decision == "approve" && r.by == "me" && r.editedFields == nil)
        #expect(NextEligibility.isEligible(t, lookup: rig.store.allTasks()), "approved tasks are visible again")
    }

    @Test func approveWithEditsRecordsWhatTheOwnerChanged() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        let id = try pending(rig, a)
        #expect(AgentReview.approve(id, editedFields: ["due", "project"], store: rig.store))
        let r = try #require(AgentTaskResult.decode(rig.store.task(id)?.resultJSON))
        #expect(r.decision == "edit" && r.editedFields == ["due", "project"])
    }

    @Test func approvingAnUpdateAppliesThePatchAndSpendsTheProposalRow() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        let target = rig.store.createNoUndo(title: "Meeting", priority: .low)
        let r = try rig.call("propose_update", ["id": target.id.uuidString,
                                                "patch": ["due": "2026-10-06", "priority": "high", "title": "Meeting moved", "notesAppend": "Client moved it"]], as: a)
        let shadow = try rig.uuid(r.str("proposalTaskID"))
        #expect(AgentReview.approve(shadow, store: rig.store))
        let t = try #require(rig.store.task(target.id))
        #expect(t.priority == .high && t.dueDay == Day.parseISO("2026-10-06") && t.title == "Meeting moved" && t.notes == "Client moved it")
        #expect(rig.store.task(shadow) == nil, "the proposal row is gone from every list")
    }

    @Test func approvingAnUpdateIsOneUndoStep() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        let target = rig.store.createNoUndo(title: "Meeting", priority: .low)
        let r = try rig.call("propose_update", ["id": target.id.uuidString, "patch": ["priority": "high"]], as: a)
        let shadow = try rig.uuid(r.str("proposalTaskID"))
        #expect(AgentReview.approve(shadow, store: rig.store))
        rig.store.undo()
        #expect(rig.store.task(target.id)?.priority == .low && rig.store.task(shadow)?.reviewRaw == ReviewState.pending,
                "one undo reverts the patch and brings the proposal back")
    }

    @Test func rejectRemovesTheRowKeepsTheReasonAndReportsRejected() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        let id = try pending(rig, a)
        #expect(AgentReview.reject(id, reason: "  duplicate of the other task  ", store: rig.store))
        #expect(rig.store.task(id) == nil)
        let t = try #require(rig.store.taskIncludingDeleted(id))
        #expect(t.reviewRaw == ReviewState.rejected)
        let r = try #require(AgentTaskResult.decode(t.resultJSON))
        #expect(r.reason == "duplicate of the other task" && r.decision == "reject" && r.outcome == "rejected")
        #expect(AgentReview.reject(id, reason: nil, store: rig.store) == false, "only a pending proposal can be rejected")
    }

    @Test func rejectWithoutAReasonLeavesNoReason() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        let id = try pending(rig, a)
        #expect(AgentReview.reject(id, reason: "   ", store: rig.store))
        #expect(AgentTaskResult.decode(rig.store.taskIncludingDeleted(id)?.resultJSON)?.reason == nil)
    }

    @Test func rejectingIsUndoable() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        let id = try pending(rig, a)
        #expect(AgentReview.reject(id, reason: "no", store: rig.store))
        rig.store.undo()
        #expect(rig.store.task(id)?.reviewRaw == ReviewState.pending)
    }

    @Test func approveAndRejectRefuseATaskThatIsNotPending() throws {
        let rig = try AgentRig()
        let plain = rig.store.createNoUndo(title: "Plain")
        #expect(AgentReview.approve(plain.id, store: rig.store) == false)
        #expect(AgentReview.reject(plain.id, reason: nil, store: rig.store) == false)
        #expect(AgentReview.approve(UUID(), store: rig.store) == false)
        #expect(rig.store.task(plain.id)?.reviewRaw == 0)
    }

    @Test func approveBatchApprovesEveryTaskOfOneProposalAndNoOther() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        let p1 = try rig.call("propose_tasks", ["title": "One", "tasks": [["title": "a"], ["title": "b"]]], as: a)
        let p2 = try rig.call("propose_tasks", ["title": "Two", "tasks": [["title": "c"]]], as: a)
        let proposal1 = try rig.uuid(p1.str("proposalID"))
        #expect(AgentReview.approveBatch(proposalID: proposal1, store: rig.store) == 2)
        let other = try rig.uuid((p2.body["taskIDs"] as? [String])?.first)
        #expect(rig.store.task(other)?.reviewRaw == ReviewState.pending)
    }

    // MARK: agent done

    private func awaiting(_ rig: AgentRig) throws -> (AgentIdentity, UUID) {
        let a = rig.agent("relay", scopes: AgentScopes([.read, .propose, .writeOwn, .writeTrusted]))
        let id = try rig.taskID(rig.call("create_task", ["title": "Draft reply", "assignee": "self"], as: a))
        _ = try rig.call("complete_task", ["id": id.uuidString, "result": ["note": "Draft written"]], as: a)
        return (a, id)
    }

    @Test func acceptingAgentDoneClosesTheTaskWithTheAgentsNoteAndTheAgentHearsIt() throws {
        let rig = try AgentRig()
        let (a, id) = try awaiting(rig)
        #expect(AgentReview.acceptAgentDone(id, store: rig.store))
        let t = try #require(rig.store.task(id))
        #expect(t.status == .done && t.reviewRaw == ReviewState.approved)
        #expect(AgentTaskResult.decode(t.resultJSON)?.note == "Draft written")
        rig.hub.sync(store: rig.store)
        let e = try #require(rig.hub.events(for: a, since: 0).events.first)
        #expect(e.verb == ActivityVerb.completed && e.actor == "me", "accepting is the owner finishing it")
        #expect(AgentHub.payload(e)["note"]?.string == "Draft written")
    }

    @Test func reopeningKeepsTheTaskOpenStoresTheCommentAndTheAgentHearsReopened() throws {
        let rig = try AgentRig()
        let (a, id) = try awaiting(rig)
        #expect(AgentReview.reopen(id, comment: "The link is missing", store: rig.store))
        let t = try #require(rig.store.task(id))
        #expect(t.status == .todo && t.reviewRaw == ReviewState.none && t.assigneeRaw == 1, "still the agent's to do")
        #expect(AgentContext.decode(t.contextJSON)?.comments?.last?.text == "The link is missing")
        rig.hub.sync(store: rig.store)
        let e = try #require(rig.hub.events(for: a, since: 0).events.first)
        #expect(e.verb == ActivityVerb.reopened && AgentHub.payload(e)["note"]?.string == "The link is missing")
    }

    @Test func acceptAndReopenOnlyApplyToATaskAwaitingACheck() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        let id = try pending(rig, a)
        #expect(AgentReview.acceptAgentDone(id, store: rig.store) == false)
        #expect(AgentReview.reopen(id, comment: "x", store: rig.store) == false)
    }

    @Test func theReviewConstantsMatchTheWireNames() {
        let wire: [Int] = [ReviewState.none, ReviewState.pending, ReviewState.approved, ReviewState.rejected, ReviewState.awaitingCheck]
        #expect(wire == [0, 1, 2, 3, 4])
        #expect(MCPTaskFull.reviewName(1) == "pending" && MCPTaskFull.reviewName(4) == "awaitingCheck" && MCPTaskFull.reviewName(0) == nil)
    }
}

#endif
