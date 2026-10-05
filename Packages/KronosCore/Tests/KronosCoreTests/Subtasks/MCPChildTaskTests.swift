#if os(macOS)
import Testing
import Foundation
@testable import KronosCore

/// MCP on child-task subtasks: lists exclude them unless asked, get_task returns them as full
/// tasks, add_subtask creates one, toggle_subtask stays an alias, and task tools act on them.
@MainActor
@Suite("MCPChildTaskTests")
struct MCPChildTaskTests {

    private func call(_ d: MCPDispatcher, _ tool: String, _ args: [String: Any]) throws -> (isError: Bool, body: [String: Any]) {
        let envelope: [String: Any] = ["name": tool, "arguments": args]
        let request = MCPRequest(id: .number(1), method: "tools/call",
                                 paramsData: try JSONSerialization.data(withJSONObject: envelope))
        let response = try #require(d.handle(request))
        let raw = try #require(response.result)
        let obj = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        return ((obj["isError"] as? Bool) ?? false, obj["structuredContent"] as? [String: Any] ?? [:])
    }

    private func titles(_ body: [String: Any]) -> [String] {
        ((body["tasks"] as? [[String: Any]]) ?? []).compactMap { $0["title"] as? String }.sorted()
    }

    @Test func listTasksExcludesSubtasksUnlessAsked() throws {
        let store = try TaskStore(inMemory: true)
        let d = MCPDispatcher(store: store, ranking: RankingEngine())
        let p = store.createNoUndo(title: "Plan trip")
        _ = try #require(store.addSubtaskNoUndo(p.id, title: "Book train"))

        let plain = try call(d, "list_tasks", ["view": "all"])
        #expect(plain.isError == false)
        #expect(titles(plain.body) == ["Plan trip"])

        let withSubs = try call(d, "list_tasks", ["view": "all", "includeSubtasks": true])
        #expect(titles(withSubs.body) == ["Book train", "Plan trip"])
        let row = try #require((withSubs.body["tasks"] as? [[String: Any]])?.first { $0["title"] as? String == "Book train" })
        #expect(row["parentID"] as? String == p.id.uuidString)
    }

    @Test func getTaskReturnsChildrenAsFullTasksAndAddSubtaskMakesOne() throws {
        let store = try TaskStore(inMemory: true)
        let d = MCPDispatcher(store: store, ranking: RankingEngine())
        let p = store.createNoUndo(title: "Plan trip")

        let added = try call(d, "add_subtask", ["taskID": p.id.uuidString, "title": "Book train", "priority": 2])
        #expect(added.isError == false)
        let subID = try #require((added.body["subtask"] as? [String: Any])?["id"] as? String)
        #expect(store.task(UUID(uuidString: subID)!)?.parentID == p.id)

        let got = try call(d, "get_task", ["id": p.id.uuidString])
        let children = try #require(got.body["children"] as? [[String: Any]])
        #expect(children.count == 1)
        #expect(children[0]["id"] as? String == subID)
        #expect(children[0]["title"] as? String == "Book train")
        #expect(children[0]["priority"] as? String == "medium")
        #expect(children[0]["parentID"] as? String == p.id.uuidString)
        #expect(children[0]["notes"] != nil, "a child is a full task object")

        // a subtask cannot take subtasks
        let nested = try call(d, "add_subtask", ["taskID": subID, "title": "too deep"])
        #expect(nested.isError == true)
    }

    @Test func taskToolsWorkOnAChildAndToggleIsAnAlias() throws {
        let store = try TaskStore(inMemory: true)
        let d = MCPDispatcher(store: store, ranking: RankingEngine())
        let p = store.createNoUndo(title: "Plan trip")
        let c = try #require(store.addSubtaskNoUndo(p.id, title: "Book train"))

        let upd = try call(d, "update_task", ["id": c.id.uuidString, "due": "2026-11-03"])
        #expect(upd.isError == false)
        #expect(SubtaskFixture.iso(store.task(c.id)?.dueDay) == "2026-11-03")
        #expect(SubtaskFixture.iso(store.task(p.id)?.effectiveDue) == "2026-11-03")

        let toggled = try call(d, "toggle_subtask", ["id": c.id.uuidString, "isDone": true])
        #expect(toggled.isError == false)
        #expect(store.task(c.id)?.status == .done)
        let again = try call(d, "toggle_subtask", ["id": c.id.uuidString, "isDone": true])
        #expect(again.isError == false)
        #expect(store.task(c.id)?.status == .done, "explicit isDone is idempotent")

        let reopened = try call(d, "update_task", ["id": c.id.uuidString, "status": "todo"])
        #expect(reopened.isError == false)
        #expect(store.task(c.id)?.status == .todo)

        let gone = try call(d, "delete_task", ["id": c.id.uuidString, "confirm": true])
        #expect(gone.isError == false)
        #expect(store.task(p.id)?.orderedChildren.isEmpty == true)
        #expect(store.undoDepth == 0, "MCP writes push no undo step")
    }
}

#endif
