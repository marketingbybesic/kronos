import Testing
import Foundation
@testable import KronosCore

/// Transport and field size limits. Expected values are hand-written (20 / 500 / 20 000, from the
/// product decision), never read back from `MCPLimits`; the boundary is tested on both sides.
@MainActor
private enum Harness {
    static func make() throws -> (TaskStore, MCPDispatcher) {
        let store = try TaskStore(inMemory: true)
        return (store, MCPDispatcher(store: store, ranking: RankingEngine()))
    }

    static func toolCall(_ id: Int, _ tool: String, _ args: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": tool, "arguments": args]]
    }

    static func ping(_ id: Int) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "method": "ping"] }

    static func body(_ object: Any) -> Data { (try? JSONSerialization.data(withJSONObject: object)) ?? Data() }

    static func parse(_ data: Data?) throws -> Any {
        try JSONSerialization.jsonObject(with: data ?? Data())
    }

    /// The structuredContent of a tools/call answered through the real body entry point.
    static func result(_ d: MCPDispatcher, _ tool: String, _ args: [String: Any]) -> (isError: Bool, content: [String: Any]) {
        let reply = d.handleBody(body(toolCall(1, tool, args)))
        let obj = (try? JSONSerialization.jsonObject(with: reply.body ?? Data())) as? [String: Any] ?? [:]
        let res = obj["result"] as? [String: Any] ?? [:]
        return ((res["isError"] as? Bool) ?? false, res["structuredContent"] as? [String: Any] ?? [:])
    }
}

@MainActor
@Suite struct MCPBatchCapTests {

    @Test func batchOfTwentyOneIsRejectedWholeAndNothingRuns() throws {
        let (store, d) = try Harness.make()
        let batch = (1...21).map { Harness.toolCall($0, "create_task", ["title": "T\($0)"]) }
        let reply = d.handleBody(Harness.body(batch))
        #expect(reply.status == 200)
        #expect(reply.mutated == false)
        let obj = try #require(Harness.parse(reply.body) as? [String: Any])
        let error = try #require(obj["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32602)
        #expect((error["message"] as? String)?.contains("21") == true)
        #expect(obj["id"] is NSNull)
        #expect(store.allTasks().isEmpty, "a rejected batch must not run any of its requests")
    }

    @Test func batchOfTwentyIsAnsweredInFull() throws {
        let (store, d) = try Harness.make()
        let batch = (1...20).map { Harness.toolCall($0, "create_task", ["title": "T\($0)"]) }
        let reply = d.handleBody(Harness.body(batch))
        #expect(reply.mutated)
        let arr = try #require(Harness.parse(reply.body) as? [[String: Any]])
        #expect(arr.count == 20)
        #expect(arr.allSatisfy { $0["error"] == nil })
        #expect(store.allTasks().count == 20)
    }

    @Test func singleAndSmallBatchesStillWork() throws {
        let (_, d) = try Harness.make()
        let one = d.handleBody(Harness.body([Harness.ping(1)]))
        let arr = try #require(Harness.parse(one.body) as? [[String: Any]])
        #expect(arr.count == 1)
        let plain = d.handleBody(Harness.body(Harness.ping(7)))
        let obj = try #require(Harness.parse(plain.body) as? [String: Any])
        #expect(obj["id"] as? Int == 7)
        #expect(obj["error"] == nil)
    }

    @Test func twentyOnePingsAreAlsoRejected() throws {
        let (_, d) = try Harness.make()
        let reply = d.handleBody(Harness.body((1...21).map { Harness.ping($0) }))
        let obj = try #require(Harness.parse(reply.body) as? [String: Any])
        #expect((obj["error"] as? [String: Any])?["code"] as? Int == -32602)
    }
}

@MainActor
@Suite struct MCPFieldLimitTests {

    // (label, length, repeated unit, accepted)
    private static let titleRows: [(String, Int, String, Bool)] = [
        ("500 ascii", 500, "a", true),
        ("501 ascii", 501, "a", false),
        ("500 two-byte letters", 500, "é", true),
        ("500 emoji (2000 bytes)", 500, "🙂", true),
        ("501 emoji", 501, "🙂", false),
        ("1 char", 1, "x", true),
    ]

    @Test func createTaskTitle() throws {
        for (label, count, unit, accepted) in Self.titleRows {
            let (store, d) = try Harness.make()
            let r = Harness.result(d, "create_task", ["title": String(repeating: unit, count: count)])
            #expect(r.isError == !accepted, "create_task title: \(label)")
            #expect(store.allTasks().count == (accepted ? 1 : 0), "create_task title: \(label) store count")
            if !accepted {
                #expect(r.content["error"] as? String == "INVALID_PARAMS", "\(label)")
                #expect((r.content["data"] as? [String: Any])?["field"] as? String == "title", "\(label)")
                #expect((r.content["message"] as? String)?.contains("title") == true, "\(label)")
            }
        }
    }

    @Test func updateTaskTitle() throws {
        for (label, count, unit, accepted) in Self.titleRows {
            let (store, d) = try Harness.make()
            let t = store.createNoUndo(title: "Original")
            let r = Harness.result(d, "update_task", ["id": t.id.uuidString, "title": String(repeating: unit, count: count)])
            #expect(r.isError == !accepted, "update_task title: \(label)")
            #expect((store.task(t.id)?.title == "Original") == !accepted, "update_task title: \(label) stored")
            if !accepted { #expect((r.content["data"] as? [String: Any])?["field"] as? String == "title", "\(label)") }
        }
    }

    @Test func addSubtaskTitle() throws {
        for (label, count, unit, accepted) in Self.titleRows {
            let (store, d) = try Harness.make()
            let t = store.createNoUndo(title: "Parent")
            let r = Harness.result(d, "add_subtask", ["taskID": t.id.uuidString, "title": String(repeating: unit, count: count)])
            #expect(r.isError == !accepted, "add_subtask title: \(label)")
            #expect((store.task(t.id)?.orderedChildren.count ?? -1) == (accepted ? 1 : 0), "add_subtask: \(label)")
            if !accepted { #expect((r.content["data"] as? [String: Any])?["field"] as? String == "title", "\(label)") }
        }
    }

    @Test func createTaskSubtasksEntries() throws {
        let (store, d) = try Harness.make()
        let tooLong = Harness.result(d, "create_task", ["title": "Parent", "subtasks": ["ok", String(repeating: "a", count: 501)]])
        #expect(tooLong.isError)
        #expect(store.allTasks().isEmpty, "nothing is created when one step title is too long")
        let fine = Harness.result(d, "create_task", ["title": "Parent", "subtasks": ["ok", String(repeating: "a", count: 500)]])
        #expect(fine.isError == false)
        #expect(store.allTasks().count == 1)
    }

    // (label, length, unit, accepted)
    private static let notesRows: [(String, Int, String, Bool)] = [
        ("20000 ascii", 20_000, "n", true),
        ("20001 ascii", 20_001, "n", false),
        ("20000 emoji (80000 bytes)", 20_000, "🙂", true),
        ("20001 emoji", 20_001, "🙂", false),
        ("empty", 0, "n", true),
    ]

    @Test func notesBoundaryOnCreate() throws {
        for (label, count, unit, accepted) in Self.notesRows {
            let (store, d) = try Harness.make()
            let r = Harness.result(d, "create_task", ["title": "T", "notes": String(repeating: unit, count: count)])
            #expect(r.isError == !accepted, "create_task notes: \(label)")
            #expect(store.allTasks().count == (accepted ? 1 : 0), "create_task notes: \(label) store count")
            if !accepted {
                #expect(r.content["error"] as? String == "INVALID_PARAMS", "\(label)")
                #expect((r.content["data"] as? [String: Any])?["field"] as? String == "notes", "\(label)")
            }
        }
    }

    @Test func notesBoundaryOnUpdate() throws {
        for (label, count, unit, accepted) in Self.notesRows {
            let (store, d) = try Harness.make()
            let t = store.createNoUndo(title: "T", notes: "before")
            let r = Harness.result(d, "update_task", ["id": t.id.uuidString, "notes": String(repeating: unit, count: count)])
            #expect(r.isError == !accepted, "update_task notes: \(label)")
            #expect((store.task(t.id)?.notes == "before") == !accepted, "update_task notes: \(label) stored")
            if !accepted { #expect((r.content["data"] as? [String: Any])?["field"] as? String == "notes", "\(label)") }
        }
    }

    @Test func rejectedUpdateChangesNothingElse() throws {
        let (store, d) = try Harness.make()
        let t = store.createNoUndo(title: "Keep")
        let r = Harness.result(d, "update_task", ["id": t.id.uuidString, "priority": "high",
                                                  "notes": String(repeating: "n", count: 20_001)])
        #expect(r.isError)
        #expect(store.task(t.id)?.priority == KPriority.none, "a rejected call applies none of its fields")
    }

    @Test func titleFromQuickAddTextIsHeldToTheSameLimit() throws {
        let (store, d) = try Harness.make()
        let r = Harness.result(d, "create_task", ["text": String(repeating: "a", count: 501)])
        #expect(r.isError)
        #expect(store.allTasks().isEmpty)
    }
}
