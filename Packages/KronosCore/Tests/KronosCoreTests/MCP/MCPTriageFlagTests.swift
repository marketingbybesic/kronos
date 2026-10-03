import Testing
import Foundation
@testable import KronosCore

/// What a machine write through MCP leaves on a task: with `triage` false or absent the task is
/// not queued for triage, no field was filled, and the person's undo depth did not move.
@MainActor
@Suite struct MCPTriageFlagTests {

    private func make() throws -> (TaskStore, MCPDispatcher) {
        let store = try TaskStore(inMemory: true)
        return (store, MCPDispatcher(store: store, ranking: RankingEngine()))
    }

    private func taskID(_ task: [String: Any]) throws -> UUID {
        let raw = try #require(task["id"] as? String)
        return try #require(UUID(uuidString: raw))
    }

    private func create(_ d: MCPDispatcher, _ args: [String: Any]) -> (isError: Bool, task: [String: Any], protected: [String]) {
        let envelope: [String: Any] = ["name": "create_task", "arguments": args]
        let params = (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
        let response = d.handle(MCPRequest(id: .number(1), method: "tools/call", paramsData: params))!
        let res = (try? JSONSerialization.jsonObject(with: response.result!)) as? [String: Any] ?? [:]
        let content = res["structuredContent"] as? [String: Any] ?? [:]
        return ((res["isError"] as? Bool) ?? false, content["task"] as? [String: Any] ?? [:],
                content["protectedFields"] as? [String] ?? [])
    }

    @Test func triageFalseAndDefaultFillNothingAndKeepUndoDepth() throws {
        for args in [["title": "Buy milk", "triage": false] as [String: Any], ["title": "Buy milk"]] {
            let (store, d) = try make()
            _ = store.create(title: "Owner's own task")          // one real undo step
            let depthBefore = store.undoDepth
            let r = create(d, args)
            #expect(!r.isError)
            let id = try taskID(r.task)
            let t = try #require(store.task(id))
            #expect(t.needsTriage == false, "args \(args.keys.sorted())")
            #expect(t.priority == KPriority.none)
            #expect(t.dueDay == nil)
            #expect(t.project == nil)
            #expect(t.firstMove == nil)
            #expect(t.depth == KDepth.unknown)
            #expect(t.estimateMinutes == nil)
            #expect((t.labels ?? []).isEmpty)
            #expect(t.effort == KEffort.none)
            #expect(store.undoDepth == depthBefore, "the owner's undo depth must not move")
            #expect(r.protected.isEmpty, "nothing was set explicitly")
        }
    }

    @Test func mcpCreatedTaskIsMarkedMachineOrigin() throws {
        for args in [["title": "A"] as [String: Any], ["title": "B", "triage": true], ["title": "C", "triage": false]] {
            let (store, d) = try make()
            let r = create(d, args)
            let id = try taskID(r.task)
            #expect(store.task(id)?.source == "mcp", "args \(args.keys.sorted())")
        }
        // Positive control: a task made through the store directly is not machine-origin.
        let (store, _) = try make()
        #expect(store.create(title: "Typed by the owner").source == nil)
    }

    @Test func triageTrueQueuesTheTaskPositiveControl() throws {
        let (store, d) = try make()
        let r = create(d, ["title": "Buy milk", "triage": true])
        let id = try taskID(r.task)
        #expect(store.task(id)?.needsTriage == true)
    }

    @Test func explicitFieldsStayAndAreReportedProtected() throws {
        let (store, d) = try make()
        let r = create(d, ["title": "Pay rent", "priority": "none", "triage": false])
        let id = try taskID(r.task)
        #expect(store.task(id)?.priority == KPriority.none)
        #expect(r.protected == ["priority"], "an explicit priority:none is a decision, not an absent value")
    }
}
