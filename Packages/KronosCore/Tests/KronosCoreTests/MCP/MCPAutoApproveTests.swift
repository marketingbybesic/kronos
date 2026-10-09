#if os(macOS)
import Testing
import Foundation
@testable import KronosCore

/// `complete_task`'s auto-approve branch (AgentScope.doneTrusted, round 2 #10): an agent holding
/// the person-granted `done.trusted` scope closes a task handed to it without waiting on the
/// person's check. The negative control (same agent, no scope) and the ordinary non-delegated
/// close path (see MCPProposeTests.aTaskNotAssignedToTheAgentClosesAtOnce) stay byte-identical.
@MainActor
@Suite struct MCPAutoApproveTests {

    @Test func aTrustedAgentAutoApprovesItsOwnDelegatedCompletion() throws {
        let rig = try AgentRig()
        let a = rig.agent("relay", scopes: AgentScopes([.read, .propose, .writeOwn, .writeTrusted, .doneTrusted]))
        let id = try rig.taskID(rig.call("create_task", ["title": "Draft reply", "assignee": "self"], as: a))
        #expect(rig.store.task(id)?.assigneeRaw == 1)

        let r = try rig.call("complete_task", ["id": id.uuidString, "result": ["note": "Draft written"]], as: a)
        #expect(!r.isError && r.body["completed"] as? Bool == true && r.str("review") == "autoApproved")

        let t = try #require(rig.store.task(id))
        #expect(t.status == .done && t.reviewRaw == ReviewState.approved)
        let result = try #require(AgentTaskResult.decode(t.resultJSON))
        #expect(result.verdict == AgentReview.accepted && result.decision == "auto")
        #expect(result.by == "agent:relay" && result.note == "Draft written")

        let doneRow = try #require(rig.hub.rows().first { $0.verb == ActivityVerb.doneByAgent })
        #expect(AgentHub.payload(doneRow)["auto"]?.bool == true)
        #expect(rig.hub.rows().contains { $0.verb == ActivityVerb.completed }, "dispatchRecording logs the close too")

        let review = try rig.call("review_status", ["ids": [id.uuidString]], as: a)
        let tasks = try #require(review.body["tasks"] as? [[String: Any]])
        #expect(tasks.first?["verdict"] as? String == "approved")
    }

    @Test func withoutTheScopeTheSameAgentStillWaitsForTheOwner() throws {
        let rig = try AgentRig()
        let a = rig.agent("relay", scopes: AgentScopes([.read, .propose, .writeOwn, .writeTrusted]))
        let id = try rig.taskID(rig.call("create_task", ["title": "Draft reply", "assignee": "self"], as: a))

        let r = try rig.call("complete_task", ["id": id.uuidString, "result": ["note": "Draft written"]], as: a)
        #expect(!r.isError && r.body["completed"] as? Bool == false && r.str("review") == "awaitingCheck")

        let t = try #require(rig.store.task(id))
        #expect(t.status == .todo && t.reviewRaw == ReviewState.awaitingCheck, "no scope, no auto-approve")
    }

    @Test func aTrustedAgentClosingAnUndelegatedTaskTakesTheOrdinaryPath() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex", scopes: AgentScopes([.read, .propose, .writeOwn, .writeTrusted, .doneTrusted]))
        let id = try rig.taskID(rig.call("create_task", ["title": "Mine"], as: a))

        let r = try rig.call("complete_task", ["id": id.uuidString, "result": ["note": "Done it"]], as: a)
        #expect(!r.isError && r.body["completed"] as? Bool == true)
        #expect(r.body["review"] == nil, "a task never handed to the agent closes with no review key at all")
        #expect(rig.store.task(id)?.status == .done)
    }

    @Test func doneTrustedScopeParsesAndRoundTripsThroughCSV() {
        #expect(AgentScopes(csv: "read,done.trusted").has(.doneTrusted))
        let scopes = AgentScopes([.read, .doneTrusted])
        #expect(AgentScopes(csv: scopes.csv) == scopes)
    }
}
#endif
