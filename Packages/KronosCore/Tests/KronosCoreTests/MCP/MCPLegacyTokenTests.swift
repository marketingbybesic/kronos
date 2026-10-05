#if os(macOS)
import Testing
import Foundation
import SwiftData
@testable import KronosCore

@MainActor
@Suite struct MCPLegacyTokenTests {

    /// The identity the shared token resolves to, through the real hub path.
    private func legacy(_ rig: AgentRig, client: String? = nil) throws -> AgentIdentity {
        guard case .agent(let id) = rig.hub.authenticate(bearer: "shared", legacyToken: "shared", client: client) else {
            Issue.record("legacy token denied"); throw CancellationError()
        }
        return id
    }

    @Test func aLegacyCreateGoesPendingAndNeverShowsInTodayStyleLists() throws {
        let rig = try AgentRig()
        let me = try legacy(rig)
        let r = try rig.call("create_task", ["title": "From an old config", "due": "2026-10-02"], as: me)
        #expect(!r.isError)
        let id = try rig.taskID(r)
        let t = try #require(rig.store.task(id))
        #expect(t.reviewRaw == ReviewState.pending && t.agentID == me.agentID && t.source == "agent:unnamed")
        let task = try #require(r.body["task"] as? [String: Any])
        #expect(task["review"] as? String == "pending")
    }

    @Test func legacyReadsWork() throws {
        let rig = try AgentRig()
        let me = try legacy(rig)
        #expect(try !rig.call("list_tasks", ["view": "all"], as: me).isError)
        #expect(try !rig.call("whoami", as: me).isError)
    }

    @Test func legacyCannotUpdateCompleteDeleteOrComment() throws {
        let rig = try AgentRig()
        let me = try legacy(rig)
        let id = try rig.taskID(rig.call("create_task", ["title": "Mine"], as: me))
        for (tool, args) in [("update_task", ["id": id.uuidString, "title": "x"]), ("complete_task", ["id": id.uuidString]),
                             ("delete_task", ["id": id.uuidString, "confirm": true]), ("comment_task", ["id": id.uuidString, "text": "hi"])] as [(String, [String: Any])] {
            let r = try rig.call(tool, args, as: me)
            #expect(r.code == "FORBIDDEN", "\(tool)")
        }
        #expect(rig.store.task(id)?.title == "Mine" && rig.store.task(id)?.status == .todo)
    }

    @Test func whoamiTellsALegacyCallerItIsLegacyWithTwoScopes() throws {
        let rig = try AgentRig()
        let me = try legacy(rig, client: "Cursor")
        let r = try rig.call("whoami", as: me)
        let agent = try #require(r.body["agent"] as? [String: Any])
        #expect(agent["slug"] as? String == "cursor")
        #expect(r.body["legacy"] as? Bool == true)
        #expect(r.body["scopes"] as? [String] == ["read", "propose"])
    }

    @Test func aPerAgentTokenCallerGetsTheStandardScopesNotLegacy() throws {
        let rig = try AgentRig()
        let me = rig.agent("claude-code")
        let r = try rig.call("whoami", as: me)
        #expect(r.body["legacy"] as? Bool == false)
        #expect(r.body["scopes"] as? [String] == ["read", "propose", "write.own", "comment"])
        #expect(r.body["maxPendingProposals"] as? Int == 15)
    }

    @Test func aTrustedAgentsTasksSkipReview() throws {
        let rig = try AgentRig()
        let me = rig.agent("codex", scopes: AgentScopes([.read, .propose, .writeOwn, .writeTrusted]))
        let id = try rig.taskID(rig.call("create_task", ["title": "Straight in"], as: me))
        #expect(rig.store.task(id)?.reviewRaw == ReviewState.none)
    }

    @Test func theOwnersOwnProcessNeverCreatesPending() throws {
        let rig = try AgentRig()
        let id = try rig.taskID(rig.call("create_task", ["title": "By the owner"]))
        #expect(rig.store.task(id)?.reviewRaw == 0 && rig.store.task(id)?.agentID == nil)
    }

    @Test func aRepeatedExternalIDReturnsTheSameTaskPerAgent() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex"), b = rig.agent("relay")
        let first = try rig.call("create_task", ["title": "T", "externalID": "mail:1"], as: a)
        let again = try rig.call("create_task", ["title": "T", "externalID": "mail:1"], as: a)
        #expect(first.body["created"] as? Bool == true && again.body["created"] as? Bool == false)
        #expect(try rig.taskID(first) == rig.taskID(again))
        let other = try rig.call("create_task", ["title": "T", "externalID": "mail:1"], as: b)
        #expect(other.body["created"] as? Bool == true, "the key is per agent")
    }

    @Test func contextIsStoredButReviewBookkeepingIsNeverTakenFromTheCaller() throws {
        let rig = try AgentRig()
        let me = rig.agent("codex")
        let r = try rig.call("create_task", [
            "title": "With context",
            "context": ["why": "The editor asked for two corrections", "expectedOutcome": "Reply sent",
                        "source": ["kind": "email", "ref": "message://x", "title": "Re: PR"],
                        "links": [["url": "https://example.com/draft", "title": "Draft"]], "confidence": 0.8,
                        "kind": "update", "proposalID": UUID().uuidString, "comments": [["by": "x", "text": "y", "at": "2026-01-01T00:00:00Z"]]],
        ], as: me)
        #expect(!r.isError)
        let ctx = try #require(AgentContext.decode(rig.store.task(try rig.taskID(r))?.contextJSON))
        #expect(ctx.why == "The editor asked for two corrections" && ctx.source?.kind == "email" && ctx.confidence == 0.8)
        #expect(ctx.kind == "task", "a caller cannot make its task look like an update proposal")
        #expect(ctx.proposalID == nil && ctx.comments == nil && ctx.update == nil)
    }

    @Test func badContextIsRefusedNamingTheField() throws {
        let rig = try AgentRig()
        let me = rig.agent("codex")
        for ctx in [["why": String(repeating: "x", count: 301)], ["links": [["url": "javascript:alert(1)"]]],
                    ["confidence": 1.5], ["source": ["kind": "carrier pigeon"]]] as [[String: Any]] {
            let r = try rig.call("create_task", ["title": "x", "context": ctx], as: me)
            #expect(r.code == "INVALID_PARAMS" && (r.body["data"] as? [String: Any])?["field"] as? String == "context", "\(ctx)")
        }
        #expect(rig.store.allTasks().isEmpty)
    }
}

#endif
