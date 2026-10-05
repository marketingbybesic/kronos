#if os(macOS)
import Testing
import Foundation
@testable import KronosCore

/// Contract strictness: unknown keys, coding-path errors, annotations, aliases, descriptions.
@MainActor
@Suite struct MCPStrictParamsTests {

    private func make() throws -> (TaskStore, MCPDispatcher) {
        let store = try TaskStore(inMemory: true)
        return (store, MCPDispatcher(store: store, ranking: RankingEngine()))
    }

    private func result(_ d: MCPDispatcher, _ tool: String, _ args: [String: Any]) throws -> (isError: Bool, body: [String: Any]) {
        let params = try JSONSerialization.data(withJSONObject: ["name": tool, "arguments": args])
        let response = try #require(d.handle(MCPRequest(id: .number(1), method: "tools/call", paramsData: params)))
        let res = try #require(try? JSONSerialization.jsonObject(with: response.result ?? Data()) as? [String: Any])
        return ((res["isError"] as? Bool) ?? false, res["structuredContent"] as? [String: Any] ?? [:])
    }

    private func toolsList(_ d: MCPDispatcher) throws -> [[String: Any]] {
        let response = try #require(d.handle(MCPRequest(id: .number(2), method: "tools/list", paramsData: Data("{}".utf8))))
        let obj = try #require(try? JSONSerialization.jsonObject(with: response.result ?? Data()) as? [String: Any])
        return try #require(obj["tools"] as? [[String: Any]])
    }

    // MARK: unknown keys

    @Test func dueDayOnCreateIsRejectedNamingTheKeyAndWritesNothing() throws {
        let (store, d) = try make()
        let r = try result(d, "create_task", ["title": "T", "dueDay": "2026-12-31"])
        #expect(r.isError)
        #expect(r.body["error"] as? String == "INVALID_PARAMS")
        #expect((r.body["message"] as? String)?.contains("`dueDay`") == true)
        #expect(store.allTasks().isEmpty, "a rejected call must not create the task")
    }

    @Test func theSameCallWithTheRightKeyWorksPositiveControl() throws {
        let (store, d) = try make()
        let r = try result(d, "create_task", ["title": "T", "due": "2026-12-31"])
        #expect(!r.isError)
        #expect(store.allTasks().count == 1)
    }

    @Test func everyToolRejectsAnUnknownKeyBeforeAnyWork() throws {
        let (store, d) = try make()
        let seed = store.createNoUndo(title: "Seed")
        for tool in MCPTool.allCases {
            let r = try result(d, tool.name, ["id": seed.id.uuidString, "bogusKey": 1])
            #expect(r.isError, "\(tool.name) accepted an unknown key")
            #expect(r.body["error"] as? String == "INVALID_PARAMS", "\(tool.name)")
            #expect((r.body["message"] as? String)?.contains("`bogusKey`") == true, "\(tool.name) did not name the key")
        }
        #expect(store.allTasks().count == 1)
        #expect(store.task(seed.id)?.status == .todo)
    }

    @Test func severalUnknownKeysAreAllNamed() throws {
        let (_, d) = try make()
        let r = try result(d, "create_task", ["title": "T", "zeta": 1, "alpha": 2])
        let message = try #require(r.body["message"] as? String)
        #expect(message.contains("`alpha`") && message.contains("`zeta`"))
        #expect((r.body["data"] as? [String: Any])?["unknownKeys"] as? [String] == ["alpha", "zeta"])
    }

    @Test func nonObjectArgumentsAreInvalidParams() throws {
        let (_, d) = try make()
        let params = Data(#"{"name":"list_tasks","arguments":[1,2]}"#.utf8)
        let response = try #require(d.handle(MCPRequest(id: .number(1), method: "tools/call", paramsData: params)))
        let res = try #require(try? JSONSerialization.jsonObject(with: response.result ?? Data()) as? [String: Any])
        #expect(res["isError"] as? Bool == true)
    }

    // MARK: errors carry the coding path

    @Test func aBadValueNamesTheFieldItIsIn() throws {
        let (_, d) = try make()
        let r = try result(d, "create_task", ["title": "T", "priority": "bogus"])
        #expect(r.isError)
        #expect((r.body["message"] as? String)?.contains("`priority`") == true)
        #expect((r.body["data"] as? [String: Any])?["field"] as? String == "priority")
    }

    @Test func aBadArrayEntryNamesItsIndex() throws {
        let (_, d) = try make()
        let r = try result(d, "create_task", ["title": "T", "labels": ["ok", 5]])
        #expect((r.body["data"] as? [String: Any])?["field"] as? String == "labels[1]")
    }

    @Test func aMissingRequiredKeyIsNamed() throws {
        let (_, d) = try make()
        let r = try result(d, "add_subtask", ["title": "step"])
        #expect((r.body["message"] as? String)?.contains("`taskID`") == true)
        #expect((r.body["message"] as? String)?.contains("missing") == true)
    }

    // MARK: add_subtask aliases

    @Test func addSubtaskAcceptsDueAndANamedPriority() throws {
        let (store, d) = try make()
        let t = store.createNoUndo(title: "Parent")
        let r = try result(d, "add_subtask", ["taskID": t.id.uuidString, "title": "Step", "due": "2026-11-05", "priority": "high"])
        #expect(!r.isError)
        let sub = try #require(r.body["subtask"] as? [String: Any])
        #expect(sub["dueDay"] as? String == "2026-11-05")
        #expect(sub["priority"] as? Int == 3)
    }

    @Test func addSubtaskStillAcceptsDueDayAndANumericPriority() throws {
        let (store, d) = try make()
        let t = store.createNoUndo(title: "Parent")
        let r = try result(d, "add_subtask", ["taskID": t.id.uuidString, "title": "Step", "dueDay": "2026-11-05", "priority": 4])
        let sub = try #require(r.body["subtask"] as? [String: Any])
        #expect(sub["dueDay"] as? String == "2026-11-05")
        #expect(sub["priority"] as? Int == 4)
    }

    @Test func addSubtaskRefusesDisagreeingDueSpellings() throws {
        let (store, d) = try make()
        let t = store.createNoUndo(title: "Parent")
        let r = try result(d, "add_subtask", ["taskID": t.id.uuidString, "title": "S", "due": "2026-11-05", "dueDay": "2026-11-06"])
        #expect(r.isError)
        #expect(t.orderedChildren.isEmpty)
    }

    // MARK: annotations (hand-written table: readOnly, destructive, idempotent)

    @Test func everyToolCarriesTheAnnotationsOfTheTable() throws {
        let (_, d) = try make()
        let table: [String: (Bool, Bool, Bool)] = [
            "list_tasks": (true, false, true), "get_task": (true, false, true),
            "ordo_get": (true, false, true), "upnext_get": (true, false, true),
            "rules_list": (true, false, true), "list_projects": (true, false, true), "list_areas": (true, false, true),
            "create_task": (false, false, false), "update_task": (false, true, true),
            "complete_task": (false, false, false), "delete_task": (false, true, true),
            "restore_task": (false, false, true), "add_subtask": (false, false, false),
            "toggle_subtask": (false, false, false), "ordo_set": (false, true, true),
            "upnext_set": (false, true, true), "rules_add": (false, false, false),
            "rules_delete": (false, true, true),
            "whoami": (true, false, true), "events_poll": (true, false, true), "next": (true, false, true),
            "propose_tasks": (false, false, false), "propose_update": (false, false, false),
            "comment_task": (false, false, false), "events_ack": (false, false, true),
            "list_labels": (true, false, true), "create_label": (false, false, true), "update_label": (false, true, true),
            "create_project": (false, false, false), "update_project": (false, true, true),
            "create_area": (false, false, false), "update_area": (false, true, true),
            "delete_area": (false, true, true), "move_task": (false, true, true)
        ]
        let tools = try toolsList(d)
        #expect(tools.count == table.count)
        for t in tools {
            let name = try #require(t["name"] as? String)
            let a = try #require(t["annotations"] as? [String: Any], "\(name) has no annotations")
            let want = try #require(table[name], "\(name) is not in the table")
            #expect(a["readOnlyHint"] as? Bool == want.0, "\(name) readOnlyHint")
            #expect(a["destructiveHint"] as? Bool == want.1, "\(name) destructiveHint")
            #expect(a["idempotentHint"] as? Bool == want.2, "\(name) idempotentHint")
            #expect(a["openWorldHint"] as? Bool == false, "\(name) openWorldHint")
            #expect((a["title"] as? String)?.isEmpty == false)
        }
    }

    @Test func aReadOnlyToolIsNeverMutating() {
        for tool in MCPTool.allCases {
            #expect(tool.annotations.readOnlyHint == !tool.isMutating, "\(tool.name)")
        }
    }

    // MARK: aliases

    @Test func upnextAliasesAnswerLikeTheirTargets() throws {
        let (store, d) = try make()
        let a = store.createNoUndo(title: "A"), b = store.createNoUndo(title: "B")
        store.sendToOrdoNoUndo(a.id, top: false)
        store.sendToOrdoNoUndo(b.id, top: false)
        let old = try result(d, "ordo_get", [:])
        let new = try result(d, "upnext_get", [:])
        #expect(!old.isError && !new.isError)
        #expect(NSDictionary(dictionary: old.body).isEqual(to: new.body))
        #expect((new.body["count"] as? Int) == 2)

        let setOld = try result(d, "ordo_set", ["top": b.id.uuidString])
        let setNew = try result(d, "upnext_set", ["top": a.id.uuidString])
        #expect(!setOld.isError && !setNew.isError)
        let after = try result(d, "upnext_get", [:])
        #expect(after.body["barTaskID"] as? String == a.id.uuidString)
    }

    @Test func aliasesShareSchemaAndAnnotations() throws {
        let (_, d) = try make()
        let tools = try toolsList(d)
        func find(_ n: String) throws -> [String: Any] { try #require(tools.first { $0["name"] as? String == n }) }
        for (alias, target) in [("upnext_get", "ordo_get"), ("upnext_set", "ordo_set")] {
            let a = try find(alias), t = try find(target)
            #expect(NSDictionary(dictionary: a["inputSchema"] as? [String: Any] ?? [:]).isEqual(to: t["inputSchema"] as? [String: Any] ?? [:]))
            #expect(NSDictionary(dictionary: a["annotations"] as? [String: Any] ?? [:]).isEqual(to: t["annotations"] as? [String: Any] ?? [:]),
                    "\(alias) annotations differ from \(target)")
        }
        // Both old and new names are listed.
        let names = Set(tools.compactMap { $0["name"] as? String })
        #expect(names.isSuperset(of: ["ordo_get", "ordo_set", "upnext_get", "upnext_set"]))
    }

    @Test func aliasEnforcesTheSameStrictKeys() throws {
        let (_, d) = try make()
        #expect(try result(d, "upnext_set", ["top": UUID().uuidString, "bogus": 1]).body["error"] as? String == "INVALID_PARAMS")
        #expect(try result(d, "upnext_get", ["includeDone": true]).isError == false)
    }

    @Test func aliasesAreMutatingExactlyWhenTheirTargetIs() {
        #expect(MCPTool.upnextGet.isMutating == MCPTool.ordoGet.isMutating)
        #expect(MCPTool.upnextSet.isMutating == MCPTool.ordoSet.isMutating)
        #expect(MCPTool.upnextSet.isMutating)
    }

    // MARK: descriptions match behaviour

    @Test func listTasksCarriesTheMetaAreasItsDescriptionPromises() throws {
        let (store, d) = try make()
        let area = store.createArea(name: "Home", colorHex: "#b483ff", icon: "house")
        _ = area
        let r = try result(d, "list_tasks", ["view": "all"])
        let meta = try #require(r.body["meta"] as? [String: Any])
        let areas = try #require(meta["areas"] as? [[String: Any]])
        #expect(areas.map { $0["name"] as? String } == ["Home"])
        #expect(MCPTool.listTasks.toolDescription.contains("meta.areas"))
        #expect(meta["projects"] != nil && meta["labels"] != nil)
    }

    @Test func toolsListAndToolCountAgree() throws {
        let (_, d) = try make()
        let tools = try toolsList(d)
        #expect(tools.count == MCPTool.allCases.count)
        #expect(Set(tools.compactMap { $0["name"] as? String }) == Set(MCPTool.allCases.map(\.name)))
        for t in tools { #expect((t["description"] as? String)?.isEmpty == false) }
        // No description may claim a tool count or a tool that does not exist.
        for tool in MCPTool.allCases {
            let text = tool.toolDescription.lowercased()
            for stale in ["thirteen", "13 tools", "ordo_push", "breakdown_task", "export_json"] {
                #expect(!text.contains(stale), "\(tool.name) description mentions \(stale)")
            }
        }
    }

    @Test func initializeReportsTheBridgeVersion() throws {
        let (_, d) = try make()
        let response = try #require(d.handle(MCPRequest(id: .number(1), method: "initialize", paramsData: Data("{}".utf8))))
        let obj = try #require(try? JSONSerialization.jsonObject(with: response.result ?? Data()) as? [String: Any])
        let info = try #require(obj["serverInfo"] as? [String: Any])
        #expect(info["version"] as? String == MCPDispatcher.serverVersion)
    }
}

#endif
