import Testing
import Foundation
@testable import KronosCore

/// list_projects, list_areas, the extra list_tasks filters and strictLabels.
@MainActor
struct MCPLookupAndFilterTests {

    private func makeDispatcher() throws -> (TaskStore, MCPDispatcher) {
        let store = try TaskStore(inMemory: true)
        return (store, MCPDispatcher(store: store, ranking: RankingEngine()))
    }

    private func call(_ d: MCPDispatcher, _ tool: String, _ args: [String: Any] = [:]) -> (body: [String: Any], isError: Bool) {
        let envelope: [String: Any] = ["name": tool, "arguments": args]
        let paramsData = (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
        let response = d.handle(MCPRequest(id: .number(1), method: "tools/call", paramsData: paramsData))!
        let obj = (try? JSONSerialization.jsonObject(with: response.result!)) as? [String: Any] ?? [:]
        return (obj["structuredContent"] as? [String: Any] ?? [:], (obj["isError"] as? Bool) ?? false)
    }

    @Test func listAreasAndProjectsExposeIdsAndCounts() throws {
        let (store, d) = try makeDispatcher()
        let area = store.createArea(name: "Work", colorHex: "#112233", icon: "briefcase")
        let proj = store.createProject(name: "Acme", colorHex: "#445566", icon: nil, area: area)
        _ = store.createProject(name: "Loose", colorHex: "#445566", icon: nil, area: nil)
        _ = store.createNoUndo(title: "T1", project: proj)

        let areas = call(d, "list_areas").body["areas"] as? [[String: Any]] ?? []
        #expect(areas.count == 1)
        #expect(areas.first?["id"] as? String == area.id.uuidString)
        #expect(areas.first?["openTaskCount"] as? Int == 1)

        let all = call(d, "list_projects").body
        #expect(all["total"] as? Int == 2)
        let inArea = call(d, "list_projects", ["areaID": area.id.uuidString]).body["projects"] as? [[String: Any]] ?? []
        #expect(inArea.count == 1)
        #expect(inArea.first?["name"] as? String == "Acme")
        #expect(inArea.first?["openTaskCount"] as? Int == 1)

        #expect(call(d, "list_projects", ["areaID": UUID().uuidString]).isError)
    }

    @Test func listTasksFiltersCombine() throws {
        let (store, d) = try makeDispatcher()
        let a = store.createNoUndo(title: "A urgent", priority: .urgent, dueDay: Day.parseISO("2026-10-05"))
        _ = store.createNoUndo(title: "B low", priority: .low, dueDay: Day.parseISO("2026-10-20"))
        store.updateNoUndo(a.id) { $0.energyKind = .deepWork }

        func titles(_ args: [String: Any]) -> [String] {
            var full = args; full["view"] = "all"
            let r = call(d, "list_tasks", full)
            return (r.body["tasks"] as? [[String: Any]] ?? []).compactMap { $0["title"] as? String }
        }
        #expect(titles([:]).count == 2)
        #expect(titles(["priority": "urgent"]) == ["A urgent"])
        #expect(titles(["energyKind": "deepWork"]) == ["A urgent"])
        #expect(titles(["due": "2026-10-20"]) == ["B low"])
        #expect(titles(["dueFrom": "2026-10-01", "dueTo": "2026-10-10"]) == ["A urgent"])
        #expect(titles(["status": "done"]).isEmpty)
        #expect(call(d, "list_tasks", ["view": "all", "due": "nope"]).isError)
        #expect(call(d, "list_tasks", ["view": "all", "areaID": UUID().uuidString]).isError)
        #expect(call(d, "list_tasks", ["view": "project", "projectID": UUID().uuidString]).isError)
    }

    @Test func strictLabelsRejectsUnknownAndNeverCreates() throws {
        let (store, d) = try makeDispatcher()
        _ = store.label(named: "Known")
        #expect(call(d, "create_task", ["title": "x", "labels": ["Nope"], "strictLabels": true]).isError)
        #expect(store.allTasks().isEmpty)
        #expect(!call(d, "create_task", ["title": "x", "labels": ["known"], "strictLabels": true]).isError)
        let t = try #require(store.allTasks().first)
        #expect(call(d, "update_task", ["id": t.id.uuidString, "labels": ["Ghost"], "strictLabels": true]).isError)
        // Default stays permissive: unknown label is created.
        #expect(!call(d, "create_task", ["title": "y", "labels": ["Fresh"]]).isError)
    }
}
