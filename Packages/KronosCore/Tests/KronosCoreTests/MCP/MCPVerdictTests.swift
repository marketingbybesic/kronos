#if os(macOS)
import Testing
import Foundation
@testable import KronosCore

/// The verdict on an agent's work (Accept or Reject, with an optional comment) is the person's. The
/// agent can read it, in get_task and events_poll, and can never write or pass it.
@MainActor
@Suite struct MCPVerdictTests {

    static let trusted = AgentScopes([.read, .propose, .writeOwn, .comment, .writeTrusted])
    static let full = AgentScopes([.read, .propose, .writeOwn, .comment, .writeTrusted, .writeAll])

    /// An agent task handed to the agent and reported done: waiting for the person's check.
    private func awaiting(_ rig: AgentRig, as me: AgentIdentity) throws -> UUID {
        let made = try rig.call("create_task", ["title": "Write the summary", "assignee": "self"], as: me)
        let id = try rig.taskID(made)
        let done = try rig.call("complete_task", ["id": id.uuidString, "result": ["note": "Written and saved."]], as: me)
        #expect(done.str("review") == "awaitingCheck")
        #expect(rig.store.task(id)?.reviewRaw == ReviewState.awaitingCheck)
        return id
    }

    private func verdict(_ rig: AgentRig, _ id: UUID, as me: AgentIdentity) throws -> [String: Any]? {
        let r = try rig.call("get_task", ["id": id.uuidString], as: me)
        let task = try #require(r.body["task"] as? [String: Any])
        return task["verdict"] as? [String: Any]
    }

    private func events(_ rig: AgentRig, as me: AgentIdentity) throws -> [[String: Any]] {
        try #require(try rig.call("events_poll", [:], as: me).body["events"] as? [[String: Any]])
    }

    @Test func noVerdictBeforeTheOwnerDecides() throws {
        let rig = try AgentRig()
        let me = rig.agent("codex", scopes: Self.trusted)
        let id = try awaiting(rig, as: me)
        #expect(try verdict(rig, id, as: me) == nil)
    }

    @Test func acceptWithACommentIsReadInGetTaskAndEvents() throws {
        let rig = try AgentRig()
        let me = rig.agent("codex", scopes: Self.trusted)
        let id = try awaiting(rig, as: me)
        #expect(AgentReview.acceptAgentDone(id, comment: "  Good, ship it  ", store: rig.store))

        let v = try #require(try verdict(rig, id, as: me))
        #expect(v["decision"] as? String == "accepted")
        #expect(v["comment"] as? String == "Good, ship it")
        #expect(v["at"] is String)

        let done = try events(rig, as: me).filter { $0["kind"] as? String == ActivityVerb.completed }
        #expect(done.count == 1)
        let result = try #require(done.first?["result"] as? [String: Any])
        #expect(result["verdict"] as? String == "accepted")
        #expect(result["comment"] as? String == "Good, ship it")
        // The comment is also on the task as one more line of its thread.
        let ctx = try #require(AgentContext.decode(rig.store.task(id)?.contextJSON))
        #expect(ctx.comments?.last?.text == "Good, ship it" && ctx.comments?.last?.by == "me")
    }

    @Test func acceptWithoutACommentStillReportsTheVerdict() throws {
        let rig = try AgentRig()
        let me = rig.agent("codex", scopes: Self.trusted)
        let id = try awaiting(rig, as: me)
        #expect(AgentReview.acceptAgentDone(id, store: rig.store))
        let v = try #require(try verdict(rig, id, as: me))
        #expect(v["decision"] as? String == "accepted" && v["comment"] == nil || v["comment"] is NSNull)
        let result = try #require(try events(rig, as: me).first { $0["kind"] as? String == ActivityVerb.completed }?["result"] as? [String: Any])
        #expect(result["verdict"] as? String == "accepted" && result["comment"] == nil)
    }

    @Test func rejectWithACommentIsReadInGetTaskAndEvents() throws {
        let rig = try AgentRig()
        let me = rig.agent("codex", scopes: Self.trusted)
        let id = try awaiting(rig, as: me)
        #expect(AgentReview.reopen(id, comment: "The second paragraph is missing", store: rig.store))

        let v = try #require(try verdict(rig, id, as: me))
        #expect(v["decision"] as? String == "rejected")
        #expect(v["comment"] as? String == "The second paragraph is missing")
        #expect(rig.store.task(id)?.status != .done && rig.store.task(id)?.reviewRaw == ReviewState.none)

        let back = try events(rig, as: me).filter { $0["kind"] as? String == ActivityVerb.reopened }
        #expect(back.count == 1)
        let result = try #require(back.first?["result"] as? [String: Any])
        #expect(result["verdict"] as? String == "rejected")
        #expect(result["comment"] as? String == "The second paragraph is missing")
        #expect(result["note"] as? String == "The second paragraph is missing")
    }

    @Test func rejectOfAProposalCarriesTheReasonAsTheComment() throws {
        let rig = try AgentRig()
        let me = rig.agent("codex")
        let made = try rig.call("create_task", ["title": "Reorganise the board"], as: me)
        let id = try rig.taskID(made)
        #expect(AgentReview.reject(id, reason: "Not this quarter", store: rig.store))
        let r = try #require(AgentTaskResult.decode(rig.store.taskIncludingDeleted(id)?.resultJSON))
        #expect(r.verdict == "rejected" && r.verdictComment == "Not this quarter" && r.by == "me")
        let rejected = try events(rig, as: me).first { $0["kind"] as? String == ActivityVerb.rejected }
        let res = try #require(rejected?["result"] as? [String: Any])
        #expect(res["verdict"] as? String == "rejected" && res["comment"] as? String == "Not this quarter")
    }

    @Test func aNewReportClearsTheOldVerdict() throws {
        let rig = try AgentRig()
        let me = rig.agent("codex", scopes: Self.trusted)
        let id = try awaiting(rig, as: me)
        #expect(AgentReview.reopen(id, comment: "Again", store: rig.store))
        #expect(try verdict(rig, id, as: me) != nil)
        _ = try rig.call("complete_task", ["id": id.uuidString, "result": ["note": "Second try"]], as: me)
        #expect(rig.store.task(id)?.reviewRaw == ReviewState.awaitingCheck)
        #expect(try verdict(rig, id, as: me) == nil, "a stale verdict must not describe the new report")
    }

    // MARK: the agent can never decide

    @Test func noAgentCanSetAVerdictThroughAnyField() throws {
        let rig = try AgentRig()
        let me = rig.agent("codex", scopes: Self.full)
        let id = try awaiting(rig, as: me)
        // A forged verdict inside the report is dropped: the decoder takes note and links only.
        _ = try rig.call("complete_task", ["id": id.uuidString, "result": ["note": "x", "verdict": "accepted", "by": "me"]], as: me)
        #expect(try verdict(rig, id, as: me) == nil)
        // No key of any task tool names a verdict.
        for tool in MCPTool.allCases {
            let schema = tool.jsonSchema
            #expect(!schema.contains("\"verdict\""), "\(tool.name) must not take a verdict")
        }
        let r = try rig.call("update_task", ["id": id.uuidString, "verdict": "accepted"], as: me)
        #expect(r.code == "INVALID_PARAMS")
    }

    @Test func anAgentCannotPassItsOwnReviewEvenWithFullControl() throws {
        let rig = try AgentRig()
        let me = rig.agent("codex", scopes: Self.full)
        let id = try awaiting(rig, as: me)
        for status in ["done", "canceled", "todo", "inProgress"] {
            let r = try rig.call("update_task", ["id": id.uuidString, "status": status], as: me)
            #expect(r.code == "FORBIDDEN", "status \(status)")
        }
        #expect(rig.store.task(id)?.reviewRaw == ReviewState.awaitingCheck && rig.store.task(id)?.status != .done)
        // Ordinary edits of the same task stay allowed.
        #expect(try !rig.call("update_task", ["id": id.uuidString, "title": "Write the summary (v2)"], as: me).isError)
        // Reporting done again is the agent's own report, not a verdict.
        #expect(try !rig.call("complete_task", ["id": id.uuidString], as: me).isError)
        #expect(rig.store.task(id)?.reviewRaw == ReviewState.awaitingCheck && rig.store.task(id)?.status != .done)
    }

    @Test func anotherAgentWithFullControlCannotPassSomeoneElsesReview() throws {
        let rig = try AgentRig()
        let author = rig.agent("author", scopes: Self.trusted)
        let other = rig.agent("other", scopes: Self.full)
        let id = try awaiting(rig, as: author)
        #expect(try rig.call("complete_task", ["id": id.uuidString], as: other).code == "FORBIDDEN")
        #expect(try rig.call("update_task", ["id": id.uuidString, "status": "done"], as: other).code == "FORBIDDEN")
        #expect(rig.store.task(id)?.reviewRaw == ReviewState.awaitingCheck && rig.store.task(id)?.status != .done)
    }

    @Test func aTaskHandedToAnotherAgentCannotBeClosedByAFullControlAgent() throws {
        let rig = try AgentRig()
        let author = rig.agent("author", scopes: Self.trusted)
        let other = rig.agent("other", scopes: Self.full)
        let made = try rig.call("create_task", ["title": "Handed over", "assignee": "self"], as: author)
        let id = try rig.taskID(made)
        #expect(try rig.call("complete_task", ["id": id.uuidString], as: other).code == "FORBIDDEN")
        #expect(try rig.call("update_task", ["id": id.uuidString, "status": "done"], as: other).code == "FORBIDDEN")
        #expect(rig.store.task(id)?.status != .done)
    }

    @Test func aPendingProposalOfAnotherAgentCannotBeClosedByAFullControlAgent() throws {
        let rig = try AgentRig()
        let author = rig.agent("author")
        let other = rig.agent("other", scopes: Self.full)
        let id = try rig.taskID(try rig.call("create_task", ["title": "Waiting for review"], as: author))
        #expect(rig.store.task(id)?.reviewRaw == ReviewState.pending)
        #expect(try rig.call("complete_task", ["id": id.uuidString], as: other).code == "FORBIDDEN")
        #expect(rig.store.task(id)?.status != .done)
    }

    @Test func withoutFullControlTheOwnTaskPathIsExactlyAsBefore() throws {
        let rig = try AgentRig()
        let me = rig.agent("codex", scopes: Self.trusted)
        let id = try rig.taskID(try rig.call("create_task", ["title": "Plain own task"], as: me))
        // An own, unassigned task with no review pending: status moves freely, as before.
        #expect(try !rig.call("update_task", ["id": id.uuidString, "status": "inProgress"], as: me).isError)
        #expect(try !rig.call("complete_task", ["id": id.uuidString], as: me).isError)
        #expect(rig.store.task(id)?.status == .done)
    }
}
#endif
