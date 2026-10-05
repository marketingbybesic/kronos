#if os(macOS)
import Testing
import Foundation
@testable import KronosCore

/// MCP add_subtask takes an optional due day and priority; get_task returns them.
@MainActor
@Suite("MCPSubtaskTests")
struct MCPSubtaskTests {

    private func makeDispatcher() throws -> (TaskStore, MCPDispatcher) {
        let store = try TaskStore(inMemory: true)
        return (store, MCPDispatcher(store: store, ranking: RankingEngine()))
    }

    private func result(_ d: MCPDispatcher, _ tool: String, _ args: [String: Any]) throws -> (isError: Bool, body: [String: Any]) {
        let envelope: [String: Any] = ["name": tool, "arguments": args]
        let request = MCPRequest(id: .number(1), method: "tools/call",
                                 paramsData: try JSONSerialization.data(withJSONObject: envelope))
        let response = try #require(d.handle(request))
        let raw = try #require(response.result)
        let obj = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        return ((obj["isError"] as? Bool) ?? false, obj["structuredContent"] as? [String: Any] ?? [:])
    }

    @Test func addSubtaskWithDueAndPriorityThenGetTaskReturnsThem() throws {
        let (store, d) = try makeDispatcher()
        let t = store.createNoUndo(title: "Parent")

        let added = try result(d, "add_subtask", ["taskID": t.id.uuidString, "title": "Book venue",
                                                  "dueDay": "2026-10-15", "priority": 3])
        #expect(added.isError == false)
        let sub = try #require(added.body["subtask"] as? [String: Any])
        #expect(sub["dueDay"] as? String == "2026-10-15")
        #expect(sub["priority"] as? Int == 3)

        let got = try result(d, "get_task", ["id": t.id.uuidString])
        let subs = try #require(got.body["subtasks"] as? [[String: Any]])
        #expect(subs.count == 1)
        #expect(subs[0]["title"] as? String == "Book venue")
        #expect(subs[0]["dueDay"] as? String == "2026-10-15")
        #expect(subs[0]["priority"] as? Int == 3)

        // and the store really holds them
        let row = try #require(store.task(t.id)?.orderedSubtasks.first)
        #expect(SubtaskFixture.iso(row.dueDay) == "2026-10-15")
        #expect(row.priorityRaw == 3)
    }

    @Test func addSubtaskWithoutTheFieldsKeepsTheOldBehaviour() throws {
        let (store, d) = try makeDispatcher()
        let t = store.createNoUndo(title: "Parent")
        let added = try result(d, "add_subtask", ["taskID": t.id.uuidString, "title": "Plain"])
        #expect(added.isError == false)
        let sub = try #require(added.body["subtask"] as? [String: Any])
        #expect(sub["dueDay"] == nil || sub["dueDay"] is NSNull)
        #expect(sub["priority"] as? Int == 0)
        let row = try #require(store.task(t.id)?.orderedSubtasks.first)
        #expect(row.dueDay == nil)
        #expect(row.priorityRaw == 0)
    }

    @Test func badDueOrPriorityIsRejectedAndCreatesNothing() throws {
        let (store, d) = try makeDispatcher()
        let t = store.createNoUndo(title: "Parent")
        let badDate = try result(d, "add_subtask", ["taskID": t.id.uuidString, "title": "x", "dueDay": "next tuesday"])
        let badPrio = try result(d, "add_subtask", ["taskID": t.id.uuidString, "title": "x", "priority": 9])
        #expect(badDate.isError == true)
        #expect(badPrio.isError == true)
        #expect((store.task(t.id)?.children ?? []).isEmpty)
    }

    @Test func advertisedSchemaAcceptsTheNewFields() throws {
        let schema = MCPTool.addSubtask.jsonSchema
        let obj = try #require(JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any])
        let props = try #require(obj["properties"] as? [String: Any])
        #expect(props["dueDay"] != nil)
        #expect(props["priority"] != nil)
        let required = try #require(obj["required"] as? [String])
        #expect(Set(required) == ["taskID", "title"])
    }
}

#endif
