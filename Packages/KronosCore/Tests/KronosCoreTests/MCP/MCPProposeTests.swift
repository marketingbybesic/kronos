import Testing
import Foundation
@testable import KronosCore

@MainActor
@Suite struct MCPProposeTests {

    private func tasks(_ rig: AgentRig) -> [KTask] { rig.store.allTasks() }

    // MARK: propose_tasks

    @Test func aBatchCreatesPendingTasksSharingOneProposal() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        let r = try rig.call("propose_tasks", [
            "title": "Quarterly report follow-up",
            "context": ["why": "The editor asked for two corrections by Friday"],
            "tasks": [["title": "Fix paragraph 2", "due": "2026-10-09", "subtasks": ["Draft", "Check numbers"]],
                      ["title": "Send corrected PR", "priority": "high",
                       "context": ["why": "After the fix"]]],
        ], as: a)
        #expect(!r.isError && r.str("review") == "pending")
        let ids = try #require(r.body["taskIDs"] as? [String]).compactMap(UUID.init(uuidString:))
        let proposal = try rig.uuid(r.str("proposalID"))
        #expect(ids.count == 2)
        for id in ids {
            let t = try #require(rig.store.task(id))
            let ctx = try #require(AgentContext.decode(t.contextJSON))
            #expect(t.reviewRaw == ReviewState.pending && t.agentID == a.agentID && t.source == "agent:codex")
            #expect(ctx.proposalID == proposal && ctx.proposalTitle == "Quarterly report follow-up" && ctx.kind == "task")
        }
        let first = try #require(rig.store.task(ids[0])), second = try #require(rig.store.task(ids[1]))
        #expect(first.dueDay == Day.parseISO("2026-10-09") && first.orderedChildren.map(\.title) == ["Draft", "Check numbers"])
        #expect(AgentContext.decode(first.contextJSON)?.why == "The editor asked for two corrections by Friday", "the batch context is the default")
        #expect(AgentContext.decode(second.contextJSON)?.why == "After the fix", "a task's own context wins")
        #expect(second.priority == .high)
    }

    @Test func aBadItemCreatesNothing() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        let cases: [(String, [[String: Any]])] = [
            ("due", [["title": "ok"], ["title": "bad", "due": "someday"]]),
            ("empty title", [["title": "ok"], ["title": "  "]]),
            ("unknown project", [["title": "ok"], ["title": "x", "project": "No Such Project"]]),
            ("long title", [["title": "ok"], ["title": String(repeating: "x", count: 501)]]),
            ("long step", [["title": "ok", "subtasks": [String(repeating: "x", count: 121)]]]),
            ("context", [["title": "ok"], ["title": "x", "context": ["confidence": 7]]]),
        ]
        for (label, items) in cases {
            let r = try rig.call("propose_tasks", ["title": "Plan", "tasks": items], as: a)
            #expect(r.isError, "\(label)")
            #expect(tasks(rig).isEmpty, "\(label): nothing may be created")
        }
        #expect(rig.hub.rows().filter { $0.verb == ActivityVerb.created }.isEmpty)
    }

    @Test func atMostTwentyTasksAndAtLeastOne() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        let twenty = (1...20).map { ["title": "T\($0)"] }
        let r20 = try rig.call("propose_tasks", ["title": "Plan", "tasks": twenty], as: a)
        #expect(!r20.isError)
        #expect(tasks(rig).count == 20)
        let rig2 = try AgentRig()
        let a2 = rig2.agent("codex")
        let r21 = try rig2.call("propose_tasks", ["title": "Plan", "tasks": (1...21).map { ["title": "T\($0)"] }], as: a2)
        #expect(r21.code == "INVALID_PARAMS" && tasks(rig2).isEmpty)
        #expect(try rig2.call("propose_tasks", ["title": "Plan", "tasks": [[String: Any]]()], as: a2).code == "INVALID_PARAMS")
        #expect(try rig2.call("propose_tasks", ["title": "", "tasks": [["title": "x"]]], as: a2).code == "INVALID_PARAMS")
    }

    @Test func pendingTasksAreInvisibleToNextAndTheMenuBarChain() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        let r = try rig.call("propose_tasks", ["title": "Plan", "tasks": [["title": "Hidden", "due": Day.iso(rig.day)]]], as: a)
        let id = try rig.uuid((r.body["taskIDs"] as? [String])?.first)
        let lookup = rig.store.allTasks()
        #expect(NextEligibility.isEligible(try #require(rig.store.task(id)), lookup: lookup) == false)
        let next = try rig.call("next", as: a)
        #expect(next.body["task"] == nil, "a pending proposal is never the next task")
    }

    @Test func proposedTasksHaveEveryTriageFieldLockedAndNoTriagePending() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        let r = try rig.call("propose_tasks", ["title": "Plan", "tasks": [["title": "x"]]], as: a)
        let id = try rig.uuid((r.body["taskIDs"] as? [String])?.first)
        #expect(rig.store.task(id)?.needsTriage == false)
        #expect(rig.store.lockedFields(of: id) == Set(TriageFieldKind.allCases))
    }

    // MARK: propose_update

    @Test func aProposedUpdateLeavesTheTargetUntouchedAndWaitsOnAShadowRow() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        let target = rig.store.createNoUndo(title: "Alex's meeting", priority: .low)
        let r = try rig.call("propose_update", ["id": target.id.uuidString,
                                                "patch": ["due": "2026-10-06", "priority": "high"], "why": "Client moved the meeting"], as: a)
        #expect(!r.isError && r.str("review") == "pending")
        let t = try #require(rig.store.task(target.id))
        #expect(t.priority == .low && t.dueDay == nil && t.reviewRaw == 0, "the target is exactly as it was")
        let shadow = try #require(rig.store.task(try rig.uuid(r.str("proposalTaskID"))))
        let ctx = try #require(AgentContext.decode(shadow.contextJSON))
        #expect(shadow.reviewRaw == ReviewState.pending && ctx.kind == "update" && ctx.isUpdate)
        #expect(ctx.update?.targetID == target.id && ctx.update?.patch["priority"]?.string == "high" && ctx.why == "Client moved the meeting")
        #expect(shadow.title == "Update: Alex's meeting")
    }

    @Test func patchValidationNamesTheProblem() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        let t = rig.store.createNoUndo(title: "T")
        let cases: [(String, [String: Any])] = [
            ("empty", [:]), ("unknown key", ["status": "done"]), ("bad due", ["due": "friday"]), ("bad priority", ["priority": "huge"]),
            ("bad project", ["project": "Nowhere"]), ("bad estimate", ["estimateMinutes": 999]), ("bad effort", ["effort": "xxl"]),
            ("bad labels", ["labelsAdd": [1, 2]]), ("empty title", ["title": ""]),
        ]
        for (label, patch) in cases {
            let r = try rig.call("propose_update", ["id": t.id.uuidString, "patch": patch], as: a)
            #expect(r.code == "INVALID_PARAMS", "\(label)")
        }
        #expect(tasks(rig).count == 1, "no shadow row was made")
    }

    @Test func aTaskTheAgentOwnsIsUpdatedDirectlyNotProposed() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        let mine = try rig.taskID(rig.call("create_task", ["title": "Mine"], as: a))
        let r = try rig.call("propose_update", ["id": mine.uuidString, "patch": ["priority": "high"]], as: a)
        #expect(r.code == "INVALID_STATE" && (r.body["data"] as? [String: Any])?["hint"] as? String == "use update_task")
    }

    @Test func proposingForAMissingTaskIsNotFound() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        #expect(try rig.call("propose_update", ["id": UUID().uuidString, "patch": ["priority": "high"]], as: a).code == "NOT_FOUND")
    }

    // MARK: complete_task for a delegated task

    @Test func completingATaskAssignedToTheAgentGoesToTheOwnerToCheck() throws {
        let rig = try AgentRig()
        let a = rig.agent("relay", scopes: AgentScopes([.read, .propose, .writeOwn, .writeTrusted]))
        let id = try rig.taskID(rig.call("create_task", ["title": "Draft reply", "assignee": "self"], as: a))
        #expect(rig.store.task(id)?.assigneeRaw == 1)
        let r = try rig.call("complete_task", ["id": id.uuidString,
                                               "result": ["note": "Draft written", "links": [["url": "https://example.com/doc", "title": "Doc"]]]], as: a)
        #expect(!r.isError && r.body["completed"] as? Bool == false && r.str("review") == "awaitingCheck")
        let t = try #require(rig.store.task(id))
        #expect(t.status == .todo && t.reviewRaw == ReviewState.awaitingCheck, "the agent cannot close its delegated task")
        let result = try #require(AgentTaskResult.decode(t.resultJSON))
        #expect(result.note == "Draft written" && result.links?.first?.url == "https://example.com/doc" && result.by == "agent:relay")
        #expect(rig.hub.rows().contains { $0.verb == ActivityVerb.doneByAgent })
    }

    @Test func aTaskNotAssignedToTheAgentClosesAtOnce() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex", scopes: AgentScopes([.read, .propose, .writeOwn, .writeTrusted]))
        let id = try rig.taskID(rig.call("create_task", ["title": "Mine"], as: a))
        let r = try rig.call("complete_task", ["id": id.uuidString, "result": ["note": "Done it"]], as: a)
        #expect(r.body["completed"] as? Bool == true && rig.store.task(id)?.status == .done)
    }

    @Test func assigneeSelfNeedsAnAgentAndResultNoteHasALimit() throws {
        let rig = try AgentRig()
        #expect(try rig.call("create_task", ["title": "x", "assignee": "self"]).code == "INVALID_PARAMS")
        let a = rig.agent("codex", scopes: AgentScopes([.read, .propose, .writeOwn, .writeTrusted]))
        #expect(try rig.call("create_task", ["title": "x", "assignee": "somebody"], as: a).code == "INVALID_PARAMS")
        let id = try rig.taskID(rig.call("create_task", ["title": "x"], as: a))
        #expect(try rig.call("complete_task", ["id": id.uuidString, "result": ["note": String(repeating: "n", count: 281)]], as: a).code == "INVALID_PARAMS")
    }

    // MARK: strictness of the new tools

    @Test func everyNewToolRejectsAnUnknownKeyBeforeAnyWork() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        for tool in ["whoami", "propose_tasks", "propose_update", "comment_task", "events_poll", "events_ack", "next"] {
            let r = try rig.call(tool, ["bogusKey": 1], as: a)
            #expect(r.code == "INVALID_PARAMS" && r.message.contains("bogusKey"), "\(tool)")
        }
        #expect(tasks(rig).isEmpty)
    }

    @Test func requiredKeysAreNamedWhenMissing() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        #expect(try rig.call("propose_tasks", ["title": "x"], as: a).message.contains("tasks"))
        #expect(try rig.call("propose_update", ["id": UUID().uuidString], as: a).message.contains("patch"))
        #expect(try rig.call("comment_task", ["id": UUID().uuidString], as: a).message.contains("text"))
        #expect(try rig.call("events_ack", [:], as: a).message.contains("upTo"))
    }
}
