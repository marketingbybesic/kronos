import Testing
import Foundation
@testable import KronosCore

/// create_task with the optional `text` parameter: natural quick-add syntax read by the same
/// grammar as the app's entry field. Existing parameters keep their meaning.
@MainActor
struct MCPCreateTaskTextTests {

    private func makeDispatcher() throws -> (TaskStore, MCPDispatcher) {
        let store = try TaskStore(inMemory: true)
        return (store, MCPDispatcher(store: store, ranking: RankingEngine()))
    }

    private func call(_ d: MCPDispatcher, _ args: [String: Any]) -> (body: [String: Any], isError: Bool) {
        let envelope: [String: Any] = ["name": "create_task", "arguments": args]
        let paramsData = (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
        let response = d.handle(MCPRequest(id: .number(1), method: "tools/call", paramsData: paramsData))!
        let obj = (try? JSONSerialization.jsonObject(with: response.result!)) as? [String: Any] ?? [:]
        return (obj["structuredContent"] as? [String: Any] ?? [:], (obj["isError"] as? Bool) ?? false)
    }

    private func fixture() throws -> (TaskStore, MCPDispatcher, hit: KProject, home: KArea) {
        let (store, d) = try makeDispatcher()
        let hit = store.createProject(name: "Hit list", colorHex: "#445566", icon: nil, area: nil)
        _ = store.createProject(name: "Hit parade", colorHex: "#445566", icon: nil, area: nil)
        let home = store.createArea(name: "Home", colorHex: "#112233", icon: "house")
        _ = store.label(named: "deep work")
        return (store, d, hit, home)
    }

    @Test func textFillsProjectLabelPriorityEffortAndSubtasks() throws {
        let (store, d, hit, _) = try fixture()
        let r = call(d, ["text": "Call Anna #hit list @deep work !! *m > ask price > book slot"])
        #expect(!r.isError)
        let t = try #require(store.allTasks().first)
        #expect(t.title == "Call Anna")
        #expect(t.project?.id == hit.id)
        #expect(t.labels?.map(\.name) == ["deep work"])
        #expect(t.priority == .medium)
        #expect(t.effort == .m)
        #expect(t.orderedSubtasks.map(\.title) == ["ask price", "book slot"])
        // Fields that came from the text are protected from triage like explicit ones.
        let prot = (r.body["protectedFields"] as? [String]) ?? []
        #expect(prot == ["labels", "priority", "project"])
    }

    @Test func areaTokenFilesIntoTheArea() throws {
        let (store, d, _, home) = try fixture()
        #expect(!call(d, ["text": "Paint the door #home"]).isError)
        let t = try #require(store.allTasks().first)
        #expect(t.areaID == home.id)
        #expect(t.project == nil)
        #expect(t.title == "Paint the door")
    }

    @Test func explicitFieldsWinOverTheText() throws {
        let (store, d, hit, _) = try fixture()
        let parade = try #require(store.allProjects().first { $0.name == "Hit parade" })
        #expect(!call(d, ["text": "Call Anna #hit list !!!", "project": "Hit parade", "priority": "low",
                          "title": "Explicit title"]).isError)
        let t = try #require(store.allTasks().first)
        #expect(t.title == "Explicit title")
        #expect(t.project?.id == parade.id)
        #expect(t.project?.id != hit.id)
        #expect(t.priority == .low)
    }

    @Test func existingParametersStayExactlyAsTheyWere() throws {
        let (store, d, hit, _) = try fixture()
        // No text: a "#" in the title is NOT parsed; project comes only from `project`.
        #expect(!call(d, ["title": "Fix #hit list thing", "project": "Hit list", "priority": "high"]).isError)
        let t = try #require(store.allTasks().first)
        #expect(t.title == "Fix #hit list thing")
        #expect(t.project?.id == hit.id)
        #expect(t.priority == .high)
        // Missing title with no text is still an error.
        #expect(call(d, ["notes": "x"]).isError)
        #expect(call(d, ["title": "  "]).isError)
        #expect(store.allTasks().count == 1)
    }

    @Test func textErrors() throws {
        let (store, d, _, _) = try fixture()
        // Several tasks in one call: refused, nothing created.
        #expect(call(d, ["text": "One\nTwo"]).isError)
        // Only tokens, nothing left for a title.
        #expect(call(d, ["text": "#hit list"]).isError)
        // Unknown label with strictLabels is refused, text label included.
        #expect(call(d, ["text": "x @nosuchlabel", "strictLabels": true]).isError)
        #expect(store.allTasks().isEmpty)
        // The known label passes strict mode.
        #expect(!call(d, ["text": "x @deep work", "strictLabels": true]).isError)
        #expect(store.allTasks().count == 1)
    }

    @Test func textDateSetsDueAndExplicitDueWins() throws {
        let (store, d, _, _) = try fixture()
        #expect(!call(d, ["text": "Send offer tomorrow"]).isError)
        #expect(!call(d, ["text": "Send offer tomorrow", "due": "2031-03-04"]).isError)
        let tasks = store.allTasks().sorted { $0.createdAt < $1.createdAt }
        let tomorrow = Day.today(calendar: .current) + 1
        #expect(tasks[0].dueDay == tomorrow)
        #expect(tasks[1].dueDay == Day.parseISO("2031-03-04"))
    }

    @Test func schemaOffersTextAndKeepsTitle() {
        let schema = MCPTool.createTask.jsonSchema
        #expect(schema.contains("\"text\""))
        #expect(schema.contains("\"title\""))
        #expect(schema.contains("\"strictLabels\""))
    }
}
