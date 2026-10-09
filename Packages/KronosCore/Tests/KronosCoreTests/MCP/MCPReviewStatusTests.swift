#if os(macOS)
import Testing
import Foundation
import SwiftData
@testable import KronosCore

/// `review_status` (finish-round-1 B3; feedbackNote: ReviewFeedbackLoop): read-only, ids or
/// project input, state/verdict/reviewedAt/feedbackNote shape, and scope enforcement (covered
/// table-wide in MCPScopeTests; this file covers the shape).
@MainActor
struct MCPReviewStatusTests {

    private func makeDispatcher() throws -> (TaskStore, MCPDispatcher) {
        let store = try TaskStore(inMemory: true)
        let ctx = ModelContext(try KronosLocalStore.makeContainer(inMemory: true))
        let hub = AgentHub(context: ctx, tokenFiles: nil)
        let d = MCPDispatcher(store: store, ranking: RankingEngine())
        d.hub = hub
        return (store, d)
    }

    private func call(_ d: MCPDispatcher, _ args: [String: Any]) -> (body: [String: Any], isError: Bool) {
        let envelope: [String: Any] = ["name": "review_status", "arguments": args]
        let paramsData = (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
        let response = d.handle(MCPRequest(id: .number(1), method: "tools/call", paramsData: paramsData))!
        let obj = (try? JSONSerialization.jsonObject(with: response.result!)) as? [String: Any] ?? [:]
        return (obj["structuredContent"] as? [String: Any] ?? [:], (obj["isError"] as? Bool) ?? false)
    }

    @Test func idsShapeReportsStateVerdictAndReviewedMark() throws {
        let (store, d) = try makeDispatcher()
        let plain = store.createNoUndo(title: "Plain task")
        let done = store.createNoUndo(title: "Done task")
        store.completeNoUndo(done.id)
        d.hub?.setReviewed(true, taskID: plain.id, agentID: nil)

        let r = call(d, ["ids": [plain.id.uuidString, done.id.uuidString]])
        #expect(!r.isError)
        let tasks = r.body["tasks"] as? [[String: Any]] ?? []
        #expect(r.body["total"] as? Int == 2)
        let byID = Dictionary(uniqueKeysWithValues: tasks.compactMap { t -> (String, [String: Any])? in
            (t["id"] as? String).map { ($0, t) }
        })
        let p = try #require(byID[plain.id.uuidString])
        #expect(p["state"] as? String == "todo")
        #expect(p["verdict"] as? String == "none")
        #expect(p["reviewedAt"] != nil && !(p["reviewedAt"] is NSNull))
        #expect(p["reviewedBy"] as? String == "owner")

        let dn = try #require(byID[done.id.uuidString])
        #expect(dn["state"] as? String == "done")
        #expect(dn["verdict"] as? String == "none")
        #expect(dn["reviewedAt"] is NSNull || dn["reviewedAt"] == nil)
        #expect(dn["reviewedBy"] is NSNull || dn["reviewedBy"] == nil)
    }

    @Test func projectShapeListsEveryTaskInIt() throws {
        let (store, d) = try makeDispatcher()
        let project = store.createProject(name: "Acme", colorHex: "#445566", icon: nil)
        let inProject = store.createNoUndo(title: "In project", project: project)
        _ = store.createNoUndo(title: "Elsewhere")

        let r = call(d, ["project": project.id.uuidString])
        #expect(!r.isError)
        let tasks = r.body["tasks"] as? [[String: Any]] ?? []
        #expect(tasks.count == 1)
        #expect(tasks.first?["id"] as? String == inProject.id.uuidString)
    }

    @Test func neitherIdsNorProjectIsInvalidParams() throws {
        let (_, d) = try makeDispatcher()
        #expect(call(d, [:]).isError)
    }

    @Test func bothIdsAndProjectIsInvalidParams() throws {
        let (_, d) = try makeDispatcher()
        #expect(call(d, ["ids": [UUID().uuidString], "project": UUID().uuidString]).isError)
    }

    @Test func unknownIDIsNotFound() throws {
        let (_, d) = try makeDispatcher()
        let r = call(d, ["ids": [UUID().uuidString]])
        #expect(r.isError)
    }

    @Test func unknownProjectIsNotFound() throws {
        let (_, d) = try makeDispatcher()
        let r = call(d, ["project": UUID().uuidString])
        #expect(r.isError)
    }

    @Test func agentVerdictMapsAwaitingCheckToPending() throws {
        let (store, d) = try makeDispatcher()
        let t = store.createNoUndo(title: "Agent task")
        store.updateNoUndo(t.id) { $0.reviewRaw = ReviewState.awaitingCheck }
        let r = call(d, ["ids": [t.id.uuidString]])
        let tasks = r.body["tasks"] as? [[String: Any]] ?? []
        #expect(tasks.first?["verdict"] as? String == "pending")
    }

    @Test func unmarkingReviewedClearsIt() throws {
        let (store, d) = try makeDispatcher()
        let t = store.createNoUndo(title: "Toggle task")
        d.hub?.setReviewed(true, taskID: t.id, agentID: nil)
        #expect(d.hub?.isReviewed(t.id) == true)
        d.hub?.setReviewed(false, taskID: t.id, agentID: nil)
        #expect(d.hub?.isReviewed(t.id) == false)
        let r = call(d, ["ids": [t.id.uuidString]])
        let tasks = r.body["tasks"] as? [[String: Any]] ?? []
        #expect(tasks.first?["reviewedAt"] is NSNull || tasks.first?["reviewedAt"] == nil)
    }

    @Test func reviewStatusIsReadOnlyAndExposesNoMutation() {
        // The dispatch table calls the handler directly (no `store.update`/`NoUndo` writer
        // anywhere in MCPDispatcher+Review.swift); `isMutating` is the wire contract a client
        // and the app rely on, so this is the behavioural half of that promise.
        #expect(MCPTool.reviewStatus.isMutating == false)
    }

    @Test func feedbackNoteReportsTheOwnersWordOnAReopenedTask() throws {
        let (store, d) = try makeDispatcher()
        let t = store.createNoUndo(title: "Agent task")
        store.updateNoUndo(t.id) { $0.reviewRaw = ReviewState.awaitingCheck }
        #expect(AgentReview.reopen(t.id, comment: "The link is missing", store: store))

        let r = call(d, ["ids": [t.id.uuidString]])
        #expect(!r.isError)
        let tasks = r.body["tasks"] as? [[String: Any]] ?? []
        #expect(tasks.first?["verdict"] as? String == "none", "reopen clears the proposal-style reviewRaw back to none")
        #expect(tasks.first?["feedbackNote"] as? String == "The link is missing")
    }

    @Test func feedbackNoteIsReachableOnARejectedProposalAfterItLeavesTheStore() throws {
        let (store, d) = try makeDispatcher()
        let proposal = store.createNoUndo(title: "Spam idea")
        store.updateNoUndo(proposal.id) { $0.reviewRaw = ReviewState.pending }
        #expect(AgentReview.reject(proposal.id, reason: "Not this quarter", store: store))
        #expect(store.task(proposal.id) == nil, "a rejected proposal leaves the live store")

        let r = call(d, ["ids": [proposal.id.uuidString]])
        #expect(!r.isError, "an agent checking back on its own rejected proposal must not get notFound")
        let tasks = r.body["tasks"] as? [[String: Any]] ?? []
        #expect(tasks.first?["verdict"] as? String == "rejected")
        #expect(tasks.first?["feedbackNote"] as? String == "Not this quarter")
    }

    @Test func feedbackNoteIsNilWithoutAnOwnerComment() throws {
        let (store, d) = try makeDispatcher()
        let plain = store.createNoUndo(title: "Untouched task")
        let r = call(d, ["ids": [plain.id.uuidString]])
        let tasks = r.body["tasks"] as? [[String: Any]] ?? []
        #expect(tasks.first?["feedbackNote"] is NSNull || tasks.first?["feedbackNote"] == nil)
    }
}
#endif
