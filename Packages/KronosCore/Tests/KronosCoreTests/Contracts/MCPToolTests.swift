import Testing
import Foundation
@testable import KronosCore

/// The MCP surface is a wire contract: schemas must be real JSON, names must
/// be unique, and the params structs must decode what the schema advertises.
struct MCPToolTests {

    @Test func thirteenAlphaToolsWithUniqueNames() {
        #expect(MCPTool.allCases.count == 13)
        let names = MCPTool.allCases.map(\.name)
        #expect(Set(names).count == 13)
        // scope-12's exact alpha set.
        #expect(Set(names) == Set([
            "list_tasks", "get_task", "create_task", "update_task",
            "complete_task", "delete_task", "restore_task",
            "add_subtask", "toggle_subtask",
            "ordo_get", "ordo_set", "rules_list", "rules_add"
        ]))
    }

    @Test func everySchemaParsesAsJSONAndRejectsUnknownKeys() throws {
        for tool in MCPTool.allCases {
            let data = Data(tool.jsonSchema.utf8)
            let obj = try JSONSerialization.jsonObject(with: data)
            let dict = try #require(obj as? [String: Any], "\(tool.name) schema is not an object")

            #expect(dict["type"] as? String == "object", "\(tool.name) type")
            // Unknown input keys are rejected rather than silently ignored:
            // silent ignoring is how a client thinks it set a due date that
            // never landed.
            #expect(dict["additionalProperties"] as? Bool == false, "\(tool.name) additionalProperties")
            #expect(dict["properties"] is [String: Any], "\(tool.name) properties")
            #expect(!tool.toolDescription.isEmpty)
        }
    }

    @Test func toolsThatTakeAnIDDeclareItRequired() throws {
        let needID: [MCPTool] = [.getTask, .updateTask, .completeTask,
                                 .deleteTask, .restoreTask, .toggleSubtask]
        for tool in needID {
            let dict = try #require(try JSONSerialization.jsonObject(
                with: Data(tool.jsonSchema.utf8)) as? [String: Any])
            let required = try #require(dict["required"] as? [String], "\(tool.name)")
            #expect(required.contains("id"), "\(tool.name) must require id")
        }
    }

    @Test func readAndWriteToolsAreClassifiedCorrectly() {
        // Write tools route through the …NoUndo store variants (build-14).
        #expect(!MCPTool.listTasks.isMutating)
        #expect(!MCPTool.getTask.isMutating)
        #expect(!MCPTool.ordoGet.isMutating)
        #expect(!MCPTool.rulesList.isMutating)
        #expect(MCPTool.createTask.isMutating)
        #expect(MCPTool.ordoSet.isMutating)
        #expect(MCPTool.rulesAdd.isMutating)
        #expect(MCPTool.allCases.filter(\.isMutating).count == 9)
    }

    // MARK: - create_task field protection (build-7)

    @Test func createTaskRecordsExplicitFieldsAsProtected() throws {
        let json = #"""
        {"title":"T","firstMove":"Otvori terminal","priority":"none","due":"2026-12-31"}
        """#
        let p = try JSONDecoder().decode(MCPParams.CreateTask.self, from: Data(json.utf8))

        #expect(p.title == "T")
        #expect(p.firstMove == "Otvori terminal")
        // An explicit "none" is a decision, not an absent value: the "still
        // unset" rule alone would let triage overwrite it.
        #expect(p.priority == MCPPriority.none)
        #expect(p.protectedFields.contains("priority"))
        #expect(p.protectedFields.contains("firstMove"))
        #expect(p.protectedFields.contains("due"))
        #expect(!p.protectedFields.contains("depth"))
        // The app does not re-triage behind an MCP client's back.
        #expect(p.triage == false)
    }

    @Test func createTaskRequiresATitle() {
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(MCPParams.CreateTask.self,
                                         from: Data(#"{"notes":"no title"}"#.utf8))
        }
    }

    // MARK: - update_task null vs absent

    @Test func updateTaskDistinguishesExplicitNullFromAbsence() throws {
        let id = UUID()
        let clearing = try JSONDecoder().decode(
            MCPParams.UpdateTask.self,
            from: Data("{\"id\":\"\(id.uuidString)\",\"due\":null}".utf8))
        // Present-but-null means "clear the due date".
        #expect(clearing.due != nil)          // the outer optional is .some
        #expect(clearing.due! == nil)         // the inner value is null
        #expect(clearing.firstMove == nil)    // absent: leave alone

        let setting = try JSONDecoder().decode(
            MCPParams.UpdateTask.self,
            from: Data("{\"id\":\"\(id.uuidString)\",\"due\":\"2026-12-31\"}".utf8))
        #expect(setting.due! == "2026-12-31")

        let untouched = try JSONDecoder().decode(
            MCPParams.UpdateTask.self,
            from: Data("{\"id\":\"\(id.uuidString)\",\"title\":\"new\"}".utf8))
        #expect(untouched.due == nil)         // absent: leave alone
        #expect(untouched.title == "new")
    }

    @Test func updateTaskRoundTripsNullAndAbsentSeparately() throws {
        let id = UUID()
        let clearing = MCPParams.UpdateTask(id: id, due: .some(nil))
        let json = try #require(String(data: try JSONEncoder().encode(clearing), encoding: .utf8))
        #expect(json.contains("\"due\":null"))

        let absent = MCPParams.UpdateTask(id: id, title: "x")
        let json2 = try #require(String(data: try JSONEncoder().encode(absent), encoding: .utf8))
        #expect(!json2.contains("\"due\""))
    }

    // MARK: - validation before any write

    @Test func listTasksRejectsAProjectViewWithoutAProjectID() throws {
        let bad = try JSONDecoder().decode(MCPParams.ListTasks.self,
                                           from: Data(#"{"view":"project"}"#.utf8))
        // An empty list would read as "this project has no tasks".
        #expect(bad.validationError == .invalidParams)

        let ok = try JSONDecoder().decode(
            MCPParams.ListTasks.self,
            from: Data("{\"view\":\"project\",\"projectID\":\"\(UUID().uuidString)\"}".utf8))
        #expect(ok.validationError == nil)
    }

    @Test func listTasksEnforcesThePaginationCeiling() throws {
        let over = try JSONDecoder().decode(MCPParams.ListTasks.self,
                                            from: Data(#"{"limit":201}"#.utf8))
        #expect(over.validationError == .invalidParams)

        let at = try JSONDecoder().decode(MCPParams.ListTasks.self,
                                          from: Data(#"{"limit":200}"#.utf8))
        #expect(at.validationError == nil)

        let defaults = try JSONDecoder().decode(MCPParams.ListTasks.self, from: Data("{}".utf8))
        #expect(defaults.limit == 50)
        #expect(defaults.view == .today)
        #expect(defaults.fields == .compact)
        #expect(defaults.includeDone == false)
    }

    @Test func ordoSetDemandsExactlyOneOfOrderOrTop() {
        // Applied atomically or not at all (build-4), so the shape is checked
        // before any write rather than during one.
        #expect(MCPParams.OrdoSet().validationError == .invalidParams)
        #expect(MCPParams.OrdoSet(order: [], top: nil).validationError == .invalidParams)
        #expect(MCPParams.OrdoSet(order: [UUID()], top: UUID()).validationError == .invalidParams)

        let dup = UUID()
        #expect(MCPParams.OrdoSet(order: [dup, dup]).validationError == .invalidParams)

        #expect(MCPParams.OrdoSet(order: [UUID(), UUID()]).validationError == nil)
        #expect(MCPParams.OrdoSet(top: UUID()).validationError == nil)
    }

    @Test func deleteTaskRequiresAnExplicitConfirm() {
        #expect(MCPParams.DeleteTask(id: UUID(), confirm: false).validationError == .invalidParams)
        #expect(MCPParams.DeleteTask(id: UUID(), confirm: true).validationError == nil)
    }

    @Test func wireEnumsMapBothWaysToTheStoreEnums() {
        for s in MCPStatus.allCases { #expect(MCPStatus(s.kStatus) == s) }
        for p in MCPPriority.allCases { #expect(MCPPriority(p.kPriority) == p) }
        #expect(MCPDepth.unknown.kDepth == .unknown)
        #expect(MCPDepth.deep.kDepth == .deep)
        #expect(MCPParams.RulesAdd.Scope.impuls.kRuleScope == .impuls)
    }

    @Test func toolErrorCodesMatchTheWireSpelling() {
        #expect(MCPToolError.notFound.rawValue == "NOT_FOUND")
        #expect(MCPToolError.invalidParams.rawValue == "INVALID_PARAMS")
        #expect(MCPToolError.invalidState.rawValue == "INVALID_STATE")
        #expect(MCPToolError.invalidCursor.rawValue == "INVALID_CURSOR")
    }
}
