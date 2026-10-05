#if os(macOS)
import Testing
import Foundation
@testable import KronosCore

/// A proposal merged into an open task is an approval the agent hears as decision "merge"
/// naming the task it went into, never a rejection or a deletion.
@MainActor
@Suite struct MergeDecisionTests {

    private func verbs(_ rig: AgentRig) -> [String] {
        rig.hub.rows().filter { $0.verb != ActivityVerb.created && $0.verb != ActivityVerb.updated }.map(\.verb)
    }

    @Test func aMergedProposalIsReportedAsApprovedWithDecisionMerge() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        let target = rig.store.createNoUndo(title: "Send the contract")
        let proposal = try rig.taskID(rig.call("create_task", ["title": "Send contract"], as: a))
        #expect(rig.store.task(proposal)?.reviewRaw == ReviewState.pending)
        #expect(AgentReview.merge(proposal, into: target.id, reason: " Merged into Send the contract ", store: rig.store))
        #expect(rig.store.task(proposal) == nil, "the proposal row leaves every list")
        let row = try #require(rig.store.taskIncludingDeleted(proposal))
        #expect(row.reviewRaw == ReviewState.approved)
        let r = try #require(AgentTaskResult.decode(row.resultJSON))
        #expect(r.decision == "merge" && r.mergedInto == target.id && r.by == "me")
        #expect(r.reason == "Merged into Send the contract")

        #expect(rig.hub.sync(store: rig.store) == 1)
        #expect(verbs(rig) == [ActivityVerb.approved])
        let e = try #require(rig.hub.events(for: a, since: 0).events.first)
        let p = AgentHub.payload(e)
        #expect(p["decision"]?.string == "merge")
        #expect(p["mergedInto"]?.string == target.id.uuidString)
        #expect(p["reason"]?.string == "Merged into Send the contract")
        #expect(rig.hub.sync(store: rig.store) == 0, "a second run adds nothing")
    }

    @Test func aRejectionIsStillReportedAsRejected() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        let proposal = try rig.taskID(rig.call("create_task", ["title": "Spam"], as: a))
        #expect(AgentReview.reject(proposal, reason: "not needed", store: rig.store))
        rig.hub.sync(store: rig.store)
        #expect(verbs(rig) == [ActivityVerb.rejected])
    }

    @Test func mergeIsOneUndoStepAndOnlyForAPendingProposal() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        let target = rig.store.createNoUndo(title: "Book the venue")
        let proposal = try rig.taskID(rig.call("create_task", ["title": "Book venue"], as: a))
        #expect(AgentReview.merge(proposal, into: proposal, reason: nil, store: rig.store) == false, "never into itself")
        #expect(AgentReview.merge(proposal, into: UUID(), reason: nil, store: rig.store) == false, "target must exist")
        #expect(AgentReview.merge(target.id, into: proposal, reason: nil, store: rig.store) == false, "only a pending proposal")
        #expect(AgentReview.merge(proposal, into: target.id, reason: nil, store: rig.store))
        rig.store.undo()
        #expect(rig.store.task(proposal)?.reviewRaw == ReviewState.pending, "one undo brings the proposal back")
    }
}

#endif
