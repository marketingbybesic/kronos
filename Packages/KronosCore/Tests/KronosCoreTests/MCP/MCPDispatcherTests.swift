import Testing
import Foundation
@testable import KronosCore

/// L4 — MCP dispatcher tests. Every test builds its own in-memory TaskStore
/// so tests never interact through shared state.
@MainActor
struct MCPDispatcherTests {

    private func makeDispatcher() throws -> (TaskStore, MCPDispatcher) {
        let store = try TaskStore(inMemory: true)
        let dispatcher = MCPDispatcher(store: store, ranking: RankingEngine())
        return (store, dispatcher)
    }

    private func call(_ dispatcher: MCPDispatcher, _ tool: String, _ args: [String: Any] = [:]) -> [String: Any] {
        let argsData = (try? JSONSerialization.data(withJSONObject: args)) ?? Data("{}".utf8)
        let envelope: [String: Any] = ["name": tool, "arguments": (try? JSONSerialization.jsonObject(with: argsData)) ?? [:]]
        let paramsData = (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
        let request = MCPRequest(id: .number(1), method: "tools/call", paramsData: paramsData)
        let response = dispatcher.handle(request)!
        let resultObj = (try? JSONSerialization.jsonObject(with: response.result!)) as? [String: Any] ?? [:]
        let structured = resultObj["structuredContent"] as? [String: Any] ?? [:]
        return structured
    }

    private func isError(_ dispatcher: MCPDispatcher, _ tool: String, _ args: [String: Any] = [:]) -> Bool {
        let argsData = (try? JSONSerialization.data(withJSONObject: args)) ?? Data("{}".utf8)
        let envelope: [String: Any] = ["name": tool, "arguments": (try? JSONSerialization.jsonObject(with: argsData)) ?? [:]]
        let paramsData = (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
        let request = MCPRequest(id: .number(1), method: "tools/call", paramsData: paramsData)
        let response = dispatcher.handle(request)!
        let resultObj = (try? JSONSerialization.jsonObject(with: response.result!)) as? [String: Any] ?? [:]
        return (resultObj["isError"] as? Bool) ?? false
    }

    // MARK: - Required: allThirteenToolsDispatch

    @Test func allThirteenToolsDispatch() throws {
        let (store, d) = try makeDispatcher()
        let task = store.createNoUndo(title: "Seed")
        let sub = store.addSubtaskNoUndo(task.id, title: "Step")!

        var ran = 0
        func expectHandled(_ tool: MCPTool, _ args: [String: Any] = [:]) {
            let argsData = (try? JSONSerialization.data(withJSONObject: args)) ?? Data("{}".utf8)
            let envelope: [String: Any] = ["name": tool.name, "arguments": (try? JSONSerialization.jsonObject(with: argsData)) ?? [:]]
            let paramsData = (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
            let request = MCPRequest(id: .number(1), method: "tools/call", paramsData: paramsData)
            #expect(d.handle(request) != nil, "\(tool.name) produced no response")
            ran += 1
        }

        expectHandled(.listTasks, ["view": "inbox"])
        expectHandled(.getTask, ["id": task.id.uuidString])
        expectHandled(.createTask, ["title": "Another"])
        expectHandled(.updateTask, ["id": task.id.uuidString, "title": "Renamed"])
        expectHandled(.addSubtask, ["taskID": task.id.uuidString, "title": "More"])
        expectHandled(.toggleSubtask, ["id": sub.id.uuidString, "isDone": true])
        expectHandled(.ordoGet)
        expectHandled(.ordoSet, ["order": []])
        expectHandled(.rulesList)
        expectHandled(.rulesAdd, ["text": "No meetings before noon"])
        expectHandled(.completeTask, ["id": task.id.uuidString])
        expectHandled(.deleteTask, ["id": task.id.uuidString, "confirm": true])
        expectHandled(.restoreTask, ["id": task.id.uuidString])

        #expect(ran == 13)
        #expect(Set(MCPTool.allCases.map(\.name)).count == 13)
    }

    // MARK: - Required: rejectsMissingOrWrongBearer

    @Test func rejectsMissingOrWrongBearer() {
        let token = "abc123XYZ"
        #expect(!BearerAuth.isAuthorized(header: nil, expectedToken: token))
        #expect(!BearerAuth.isAuthorized(header: "Bearer wrong", expectedToken: token))
        #expect(!BearerAuth.isAuthorized(header: "Basic \(token)", expectedToken: token))
        #expect(!BearerAuth.isAuthorized(header: "", expectedToken: token))
        #expect(BearerAuth.isAuthorized(header: "Bearer \(token)", expectedToken: token))
    }

    // MARK: - Required: constantTimeEqualsMatchesOnlyIdenticalBytes

    @Test func constantTimeEqualsMatchesOnlyIdenticalBytes() {
        #expect(ConstantTime.equals("token123", "token123"))
        #expect(!ConstantTime.equals("token123", "token124"))
        #expect(!ConstantTime.equals("token123", "token12"))       // different length
        #expect(!ConstantTime.equals("token123", "TOKEN123"))      // case matters
        #expect(ConstantTime.equals("", ""))
        #expect(!ConstantTime.equals("", "x"))
        #expect(ConstantTime.equals(Data(), Data()))
        #expect(ConstantTime.equals([UInt8]([1, 2, 3]), [UInt8]([1, 2, 3])))
        #expect(!ConstantTime.equals([UInt8]([1, 2, 3]), [UInt8]([1, 2, 4])))
    }

    // MARK: - Required: listTasksReturnsEveryLiveTask

    @Test func listTasksReturnsEveryLiveTask() throws {
        let (store, d) = try makeDispatcher()
        let alive1 = store.createNoUndo(title: "Alive one")
        let alive2 = store.createNoUndo(title: "Alive two")
        let dead = store.createNoUndo(title: "Soft deleted")
        store.softDeleteNoUndo(dead.id)

        let result = call(d, "list_tasks", ["view": "inbox", "includeDone": true, "limit": 200])
        let tasks = result["tasks"] as? [[String: Any]] ?? []
        let ids = Set(tasks.compactMap { $0["id"] as? String })

        #expect(ids.contains(alive1.id.uuidString))
        #expect(ids.contains(alive2.id.uuidString))
        #expect(!ids.contains(dead.id.uuidString))
        #expect((result["total"] as? Int) == 2)
    }

    // MARK: - Required: mutatingToolsUseTheNoUndoPath

    @Test func mutatingToolsUseTheNoUndoPath() throws {
        let (store, d) = try makeDispatcher()
        let task = store.createNoUndo(title: "Undo probe")
        let depthBefore = store.undoDepth
        let canUndoBefore = store.canUndo

        _ = call(d, "update_task", ["id": task.id.uuidString, "title": "Changed via MCP", "priority": "high"])
        _ = call(d, "complete_task", ["id": task.id.uuidString])
        _ = call(d, "create_task", ["title": "Created via MCP", "labels": ["novi-label"]])
        let subtaskResult = call(d, "add_subtask", ["taskID": task.id.uuidString, "title": "Step via MCP"])
        if let subID = ((subtaskResult["subtask"] as? [String: Any])?["id"] as? String).flatMap(UUID.init) {
            _ = call(d, "toggle_subtask", ["id": subID.uuidString, "isDone": true])
        }
        _ = call(d, "ordo_set", ["order": [task.id.uuidString]])
        _ = call(d, "delete_task", ["id": task.id.uuidString, "confirm": true])
        _ = call(d, "restore_task", ["id": task.id.uuidString])
        _ = call(d, "rules_add", ["text": "Never work weekends"])

        #expect(store.undoDepth == depthBefore)
        #expect(store.canUndo == canUndoBefore)
    }

    // MARK: - Required: unknownToolReturnsMethodNotFound

    @Test func unknownToolReturnsMethodNotFound() throws {
        let (_, d) = try makeDispatcher()
        let envelope: [String: Any] = ["name": "delete_everything", "arguments": [String: Any]()]
        let paramsData = try JSONSerialization.data(withJSONObject: envelope)
        let request = MCPRequest(id: .number(7), method: "tools/call", paramsData: paramsData)
        let response = d.handle(request)!
        #expect(response.error?.code == MCPTransportError.methodNotFound.rawValue)
    }

    // MARK: - Required: malformedJSONReturnsParseError

    @Test func malformedJSONReturnsParseError() {
        do {
            _ = try MCPRequest.parse(Data("{not valid json".utf8))
            Issue.record("expected parse to throw")
        } catch let e as MCPTransportError {
            #expect(e == .parseError)
        } catch {
            Issue.record("wrong error type")
        }
    }

    // MARK: - Required: updateTaskNullClearsDueDateButAbsentKeyKeepsIt

    @Test func updateTaskNullClearsDueDateButAbsentKeyKeepsIt() throws {
        let (store, d) = try makeDispatcher()
        let task = store.createNoUndo(title: "Has a due date")
        store.updateNoUndo(task.id) { $0.dueDay = Day.today() }
        #expect(store.task(task.id)!.dueDay != nil)

        // Absent "due" key: leave it alone.
        _ = call(d, "update_task", ["id": task.id.uuidString, "title": "still due"])
        #expect(store.task(task.id)!.dueDay != nil)

        // Explicit null: clear it.
        let argsData = try JSONSerialization.data(withJSONObject: ["id": task.id.uuidString])
        var argsObj = try JSONSerialization.jsonObject(with: argsData) as! [String: Any]
        argsObj["due"] = NSNull()
        let envelope: [String: Any] = ["name": "update_task", "arguments": argsObj]
        let paramsData = try JSONSerialization.data(withJSONObject: envelope)
        let request = MCPRequest(id: .number(1), method: "tools/call", paramsData: paramsData)
        _ = d.handle(request)
        #expect(store.task(task.id)!.dueDay == nil)
    }

    // MARK: - Extra coverage

    @Test func initializeAdvertisesToolsCapabilityOnly() throws {
        let (_, d) = try makeDispatcher()
        let request = MCPRequest(id: .number(1), method: "initialize", paramsData: Data("{}".utf8))
        let response = d.handle(request)!
        let obj = try JSONSerialization.jsonObject(with: response.result!) as! [String: Any]
        let caps = obj["capabilities"] as! [String: Any]
        #expect(caps["tools"] != nil)
        #expect(caps["resources"] == nil)
        #expect(caps["prompts"] == nil)
    }

    @Test func notificationsInitializedGetsNoReply() throws {
        let (_, d) = try makeDispatcher()
        let request = MCPRequest(id: nil, method: "notifications/initialized", paramsData: Data("{}".utf8))
        #expect(d.handle(request) == nil)
    }

    @Test func toolsListReturnsAllThirteenWithValidSchemas() throws {
        let (_, d) = try makeDispatcher()
        let request = MCPRequest(id: .number(2), method: "tools/list", paramsData: Data("{}".utf8))
        let response = d.handle(request)!
        let obj = try JSONSerialization.jsonObject(with: response.result!) as! [String: Any]
        let tools = obj["tools"] as! [[String: Any]]
        #expect(tools.count == 13)
        for t in tools {
            #expect(t["inputSchema"] is [String: Any])
        }
    }

    @Test func createTaskWithUnknownProjectNameIsNotFound() throws {
        let (_, d) = try makeDispatcher()
        #expect(isError(d, "create_task", ["title": "x", "project": "Nonexistent Project XYZ"]))
    }

    @Test func completeTaskTwiceIsInvalidState() throws {
        let (store, d) = try makeDispatcher()
        let task = store.createNoUndo(title: "Once")
        #expect(!isError(d, "complete_task", ["id": task.id.uuidString]))
        #expect(isError(d, "complete_task", ["id": task.id.uuidString]))
    }

    @Test func deleteTaskWithoutConfirmIsInvalidParams() throws {
        let (store, d) = try makeDispatcher()
        let task = store.createNoUndo(title: "Needs confirm")
        #expect(isError(d, "delete_task", ["id": task.id.uuidString, "confirm": false]))
    }

    @Test func listTasksPaginatesWithAStableCursor() throws {
        let (store, d) = try makeDispatcher()
        for i in 0..<5 { _ = store.createNoUndo(title: "Task \(i)") }

        let page1 = call(d, "list_tasks", ["view": "inbox", "limit": 2])
        #expect((page1["returned"] as? Int) == 2)
        #expect((page1["hasMore"] as? Bool) == true)
        let cursor = page1["nextCursor"] as! String

        let page2 = call(d, "list_tasks", ["view": "inbox", "limit": 2, "cursor": cursor])
        #expect((page2["returned"] as? Int) == 2)

        let page1IDs = Set((page1["tasks"] as! [[String: Any]]).compactMap { $0["id"] as? String })
        let page2IDs = Set((page2["tasks"] as! [[String: Any]]).compactMap { $0["id"] as? String })
        #expect(page1IDs.isDisjoint(with: page2IDs))
    }

    @Test func ordoSetRejectsUnknownAndClosedTasks() throws {
        let (store, d) = try makeDispatcher()
        let done = store.createNoUndo(title: "Already done")
        store.completeNoUndo(done.id)

        #expect(isError(d, "ordo_set", ["order": [UUID().uuidString]]))
        #expect(isError(d, "ordo_set", ["order": [done.id.uuidString]]))
    }

    @Test func ordoSetIsIdempotentOnReplay() throws {
        let (store, d) = try makeDispatcher()
        let a = store.createNoUndo(title: "a")
        let b = store.createNoUndo(title: "b")
        let order = [a.id.uuidString, b.id.uuidString]

        let first = call(d, "ordo_set", ["order": order])
        let second = call(d, "ordo_set", ["order": order])
        let firstOrdo = (first["ordo"] as! [[String: Any]]).map { $0["ordoIndex"] as! Double }
        let secondOrdo = (second["ordo"] as! [[String: Any]]).map { $0["ordoIndex"] as! Double }
        #expect(firstOrdo == secondOrdo)
    }

    @Test func settingsSnippetNeverHardcodesAToken() {
        let cli = MCPSettingsSnippet.claudeCLI(token: "SECRET-TOKEN-VALUE")
        #expect(cli.contains("SECRET-TOKEN-VALUE"))
        #expect(cli.contains("127.0.0.1:47311"))
        let json = MCPSettingsSnippet.genericJSON(token: "SECRET-TOKEN-VALUE")
        #expect(json.contains("Authorization"))
    }
}
