#if os(macOS)
import Testing
import Foundation
@testable import KronosCore

@MainActor
@Suite struct MCPRunToolsTests {

    @Test func thirtyEightToolsIncludeTheRunContract() {
        #expect(MCPTool.allCases.count == 38)
        #expect(MCPTool.allCases.contains(.runStart) && MCPTool.allCases.contains(.runUpdate) && MCPTool.allCases.contains(.runFinish))
    }

    @Test func runStartOverMcpReturnsRunIDAndLeaseUntil() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex", scopes: AgentScopes([.read, .propose, .writeOwn, .writeTrusted]))
        let id = try rig.taskID(rig.call("create_task", ["title": "Mine"], as: a))
        let r = try rig.call("run_start", ["taskID": id.uuidString], as: a)
        #expect(!r.isError)
        #expect(r.body["runID"] != nil && r.body["leaseUntil"] != nil)
        #expect(rig.runs.activeRun(taskID: id) != nil)
    }

    @Test func runStartOnAnUnownedTaskNeedsWriteAllOtherwiseForbidden() throws {
        let rig = try AgentRig()
        let owner = rig.store.createNoUndo(title: "Owner's task")
        let plain = rig.agent("codex", scopes: AgentScopes([.read, .propose, .writeOwn]))
        let full = rig.agent("relay", scopes: AgentScopes([.read, .propose, .writeOwn, .writeAll]))
        let refused = try rig.call("run_start", ["taskID": owner.id.uuidString], as: plain)
        #expect(refused.code == "FORBIDDEN")
        #expect(rig.runs.activeRun(taskID: owner.id) == nil)
        // positive control: write.all reaches the same task.
        let allowed = try rig.call("run_start", ["taskID": owner.id.uuidString], as: full)
        #expect(!allowed.isError)
    }

    @Test func runStartOnAClaimedTaskAnswersConflictNamingTheHolder() throws {
        let rig = try AgentRig()
        let full = rig.agent("full", scopes: AgentScopes([.read, .propose, .writeOwn, .writeAll]))
        let other = rig.agent("other", scopes: AgentScopes([.read, .propose, .writeOwn, .writeAll]))
        let t = rig.store.createNoUndo(title: "Shared")
        _ = try rig.call("run_start", ["taskID": t.id.uuidString], as: full)
        let r = try rig.call("run_start", ["taskID": t.id.uuidString], as: other)
        #expect(r.code == "CONFLICT")
        #expect(r.message.contains("full") && r.message.contains("claimed:"))
    }

    @Test func runUpdateThenRunFinishDoneRoundTripsOverMcp() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex", scopes: AgentScopes([.read, .propose, .writeOwn, .writeTrusted]))
        let id = try rig.taskID(rig.call("create_task", ["title": "Mine"], as: a))
        let start = try rig.call("run_start", ["taskID": id.uuidString], as: a)
        let runID = try #require(start.body["runID"] as? String)
        let upd = try rig.call("run_update", ["runID": runID, "progress": 0.4, "note": "halfway",
                                              "artifactsAdd": [["kind": "commit", "ref": "abc"]]], as: a)
        #expect(!upd.isError && upd.body["leaseUntil"] != nil)
        let fin = try rig.call("run_finish", ["runID": runID, "outcome": "done", "summary": "Shipped it"], as: a)
        #expect(!fin.isError && fin.str("state") == "done")
        #expect(rig.store.task(id)?.reviewRaw == ReviewState.awaitingCheck)
    }

    @Test func runFinishNotYoursNamesTheHolder() throws {
        let rig = try AgentRig()
        let full = rig.agent("full", scopes: AgentScopes([.read, .propose, .writeOwn, .writeAll]))
        let other = rig.agent("other", scopes: AgentScopes([.read, .propose, .writeOwn, .writeAll]))
        let t = rig.store.createNoUndo(title: "Shared")
        let run = try rig.runs.start(taskID: t.id, agent: nil, launchedByKronos: false)
        rig.store.updateNoUndo(t.id) { $0.agentID = full.agentID }   // so `full` passes authorize()'s ownership gate
        let r = try rig.call("run_finish", ["runID": run.id.uuidString, "outcome": "done", "summary": "x"], as: other)
        #expect(r.code == "FORBIDDEN")
        #expect(r.message.contains("not yours:") && r.message.contains(run.id.uuidString))
    }

    @Test func badOutcomeAndBadArtifactKindAreInvalidParams() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex", scopes: AgentScopes([.read, .propose, .writeOwn, .writeTrusted]))
        let id = try rig.taskID(rig.call("create_task", ["title": "Mine"], as: a))
        let runID = try #require((try rig.call("run_start", ["taskID": id.uuidString], as: a)).body["runID"] as? String)
        #expect(try rig.call("run_finish", ["runID": runID, "outcome": "cancelled", "summary": "x"], as: a).code == "INVALID_PARAMS")
        let bad = try rig.call("run_update", ["runID": runID, "artifactsAdd": [["kind": "screenshot", "ref": "x"]]], as: a)
        #expect(bad.code == "INVALID_PARAMS")
    }

    @Test func everyRunToolRejectsAnUnknownKeyBeforeAnyWork() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex", scopes: AgentScopes([.read, .propose, .writeOwn]))
        for tool in ["run_start", "run_update", "run_finish"] {
            let r = try rig.call(tool, ["bogusKey": 1], as: a)
            #expect(r.code == "INVALID_PARAMS", "\(tool) did not reject an unknown key")
            #expect(r.message.contains("bogusKey"))
        }
        // positive control: a known key on the same tool is not rejected for being "unknown".
        let id = try rig.taskID(rig.call("create_task", ["title": "Mine"], as: a))
        #expect(try rig.call("run_start", ["taskID": id.uuidString], as: a).code != "INVALID_PARAMS")
    }

    // MARK: - Handler guards (validations the MCP layer owns, not RunStore)

    @Test func runStartRejectsALeaseOutsideTheSixtyTo7200SecondWindow() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex", scopes: AgentScopes([.read, .propose, .writeOwn, .writeTrusted]))
        let id = try rig.taskID(rig.call("create_task", ["title": "Mine"], as: a))
        for bad in [59, 7201] {
            let r = try rig.call("run_start", ["taskID": id.uuidString, "leaseSeconds": bad], as: a)
            #expect(r.code == "INVALID_PARAMS")
            #expect(r.message.contains("leaseSeconds") && r.message.contains("60-7200"))
            #expect(rig.runs.activeRun(taskID: id) == nil)   // rejected before it claims
        }
        // positive control: the window's edges themselves are accepted.
        #expect(try rig.call("run_start", ["taskID": id.uuidString, "leaseSeconds": 60], as: a).code != "INVALID_PARAMS")
    }

    @Test func runUpdateAndRunFinishCapArtifactsAddAtTwenty() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex", scopes: AgentScopes([.read, .propose, .writeOwn, .writeTrusted]))
        let id = try rig.taskID(rig.call("create_task", ["title": "Mine"], as: a))
        let runID = try #require((try rig.call("run_start", ["taskID": id.uuidString], as: a)).body["runID"] as? String)
        func artifacts(_ n: Int) -> [[String: Any]] { (0..<n).map { ["kind": "url", "ref": "https://example.com/\($0)"] } }
        for (tool, args) in [("run_update", ["runID": runID, "artifactsAdd": artifacts(21)]),
                             ("run_finish", ["runID": runID, "outcome": "done", "summary": "x", "artifactsAdd": artifacts(21)])] {
            let r = try rig.call(tool, args, as: a)
            #expect(r.code == "INVALID_PARAMS")
            #expect(r.message.contains("artifactsAdd") && r.message.contains("20"))
        }
        #expect(rig.runs.run(id: UUID(uuidString: runID)!)?.stateRaw == "running")   // still un-mutated
        // positive control: exactly 20 entries is accepted, not the cap itself.
        let ok = try rig.call("run_update", ["runID": runID, "artifactsAdd": artifacts(20)], as: a)
        #expect(ok.code != "INVALID_PARAMS")
    }

    @Test func runFinishRejectsAnEmptyOrOverlongSummaryBeforeAnyWork() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex", scopes: AgentScopes([.read, .propose, .writeOwn, .writeTrusted]))
        let id = try rig.taskID(rig.call("create_task", ["title": "Mine"], as: a))
        let runID = try #require((try rig.call("run_start", ["taskID": id.uuidString], as: a)).body["runID"] as? String)
        let long = String(repeating: "x", count: 2001)
        for bad in ["", long] {
            let r = try rig.call("run_finish", ["runID": runID, "outcome": "done", "summary": bad], as: a)
            #expect(r.code == "INVALID_PARAMS")
            #expect(r.message.contains("summary") && r.message.contains("1-2000"))
        }
        #expect(rig.runs.run(id: UUID(uuidString: runID)!)?.stateRaw == "running")
        #expect(rig.store.task(id)?.status != .done)   // the task was never completed
    }

    @Test func runFinishHandoffWithoutHandoffToIsRefusedBeforeAnyWork() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex", scopes: AgentScopes([.read, .propose, .writeOwn, .writeTrusted]))
        let id = try rig.taskID(rig.call("create_task", ["title": "Mine"], as: a))
        let runID = try #require((try rig.call("run_start", ["taskID": id.uuidString], as: a)).body["runID"] as? String)
        let r = try rig.call("run_finish", ["runID": runID, "outcome": "handoff", "summary": "x"], as: a)
        #expect(r.code == "INVALID_PARAMS")
        #expect(r.message.contains("handoff") && r.message.contains("handoffTo"))
        #expect(rig.runs.run(id: UUID(uuidString: runID)!)?.stateRaw == "running")
    }

    // MARK: - Error mapping: every refusal names the right next step

    @Test func runStartRefusalsNameWhatToDoNext() throws {
        let rig = try AgentRig()
        // untrusted: its create_task is pending, so run_start on it is refused with the approve-first hint.
        let untrusted = rig.agent("untrusted", scopes: AgentScopes([.read, .propose, .writeOwn]))
        let pendingID = try rig.taskID(rig.call("create_task", ["title": "Pending"], as: untrusted))
        let pending = try rig.call("run_start", ["taskID": pendingID.uuidString], as: untrusted)
        #expect(pending.code == "INVALID_STATE")
        #expect(pending.message.contains("not approved"))
        // a task the agent owns but already finished is a different refusal with its own hint.
        let a = rig.agent("codex", scopes: AgentScopes([.read, .propose, .writeOwn]))
        let doneID = try rig.taskID(rig.call("create_task", ["title": "Done"], as: a))
        rig.store.updateNoUndo(doneID) { $0.status = .done }
        let done = try rig.call("run_start", ["taskID": doneID.uuidString], as: a)
        #expect(done.code == "INVALID_STATE")
        #expect(done.message.contains("already done"))
        // a UUID that names no task is NOT_FOUND, not a claim conflict.
        let missing = try rig.call("run_start", ["taskID": UUID().uuidString], as: a)
        #expect(missing.code == "NOT_FOUND")
        #expect(missing.message.contains("no task"))
    }

    @Test func runRefusalsForUnknownAgentAndInactiveRunNameTheProblem() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex", scopes: AgentScopes([.read, .propose, .writeOwn, .writeTrusted]))
        let id = try rig.taskID(rig.call("create_task", ["title": "Mine"], as: a))
        let runID = try #require((try rig.call("run_start", ["taskID": id.uuidString], as: a)).body["runID"] as? String)
        // an unknown target slug is NOT_FOUND and says no agent has that slug.
        let handoff = try rig.call("run_finish", ["runID": runID, "outcome": "handoff", "summary": "x", "handoffTo": "ghost"], as: a)
        #expect(handoff.code == "NOT_FOUND")
        #expect(handoff.message.contains("no agent"))
        // finishing ends the run; updating the same id afterwards is INVALID_STATE with the start-anew hint.
        _ = try rig.call("run_finish", ["runID": runID, "outcome": "done", "summary": "Shipped"], as: a)
        let update = try rig.call("run_update", ["runID": runID, "note": "still going"], as: a)
        #expect(update.code == "INVALID_STATE")
        #expect(update.message.contains("not active"))
    }

    @Test func runToolsWithoutARunStoreRefuseWithoutBlamingTheAgentToken() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex", scopes: AgentScopes([.read, .propose, .writeOwn, .writeTrusted]))
        let id = try rig.taskID(rig.call("create_task", ["title": "Mine"], as: a))
        rig.dispatcher.runs = nil   // the ONE wiring gap the message must describe, not the agent's token
        let start = try rig.call("run_start", ["taskID": id.uuidString], as: a)
        #expect(start.code == "INVALID_STATE")
        #expect(start.message.contains("not set up") && !start.message.contains("agent token"))
        let update = try rig.call("run_update", ["runID": UUID().uuidString], as: a)
        #expect(update.code == "INVALID_STATE")
        #expect(update.message.contains("not set up") && !update.message.contains("agent token"))
        let finish = try rig.call("run_finish", ["runID": UUID().uuidString, "outcome": "done", "summary": "x"], as: a)
        #expect(finish.code == "INVALID_STATE")
        #expect(finish.message.contains("not set up") && !finish.message.contains("agent token"))
    }
}
#endif
