#if os(macOS)
// L4 — MCP. Read-only lookup tools (list_projects, list_areas) and the label
// existence check behind `strictLabels`. Reads only: no store mutation, so the
// app's undo history and the SQLite store are untouched.

import Foundation
import SwiftData

extension MCPDispatcher {

    // MARK: - list_projects

    func listProjects(_ arguments: Data) -> MCPToolOutcome {
        let params: MCPParams.ListProjects
        do { params = try decodeParams(MCPParams.ListProjects.self, arguments, tool: "list_projects") } catch { return MCPToolOutcome.from(error) }
        if let aid = params.areaID, !store.allAreas().contains(where: { $0.id == aid }) {
            return .error(.notFound, message: "no area \(aid)", data: ["areaID": aid.uuidString])
        }
        var projects = store.allProjects(includeArchived: params.includeArchived)
        if let aid = params.areaID { projects = projects.filter { $0.area?.id == aid } }

        let live = store.allTasks()
        let dtos: [MCPProjectDTO] = projects.map { (p: KProject) -> MCPProjectDTO in
            let mine = live.filter { $0.projectID == p.id }
            let open = mine.filter { !KStatus.closed.contains($0.status) }.count
            return MCPProjectDTO(id: p.id, name: p.name, areaID: p.area?.id, areaName: p.area?.name,
                                 icon: p.icon, emoji: p.emoji, colorHex: p.colorHex,
                                 isArchived: p.isArchived, sortIndex: p.sortIndex,
                                 openTaskCount: open, totalTaskCount: mine.count)
        }
        struct Result: Encodable { let projects: [MCPProjectDTO]; let total: Int }
        return .ok(Result(projects: dtos, total: dtos.count))
    }

    // MARK: - list_areas

    func listAreas(_ arguments: Data) -> MCPToolOutcome {
        let live = store.allTasks()
        let dtos: [MCPAreaDTO] = store.allAreas().map { (a: KArea) -> MCPAreaDTO in
            let projects = a.orderedProjects
            let ids = Set(projects.map(\.id))
            let open = live.filter { t in
                !KStatus.closed.contains(t.status) && (t.areaID == a.id || t.projectID.map(ids.contains) == true)
            }.count
            return MCPAreaDTO(id: a.id, name: a.name, colorHex: a.colorHex, icon: a.icon,
                              sortIndex: a.sortIndex,
                              projects: projects.map { MCPAreaDTO.ProjectRef(id: $0.id, name: $0.name) },
                              openTaskCount: open)
        }
        struct Result: Encodable { let areas: [MCPAreaDTO]; let total: Int }
        return .ok(Result(areas: dtos, total: dtos.count))
    }

    // MARK: - strictLabels

    /// Names from `names` that match no existing label (same folded `mergeKey` rule as
    /// `TaskStore.label(named:)`). Read-only: never creates a label. Falls back to the
    /// labels reachable through live tasks when the store is not a SwiftData `TaskStore`.
    func unknownLabels(in names: [String]) -> [String] {
        var known = Set<String>()
        if let concrete = store as? TaskStore {
            known = Set(((try? concrete.context.fetch(FetchDescriptor<KLabel>())) ?? []).map(\.mergeKey))
        } else {
            for t in store.allTasksIncludingSubtasks() { for l in t.labels ?? [] { known.insert(l.mergeKey) } }
        }
        return names.filter { !known.contains(KLabel(name: $0).mergeKey) }
    }

    func unknownLabelsError(_ missing: [String]) -> MCPToolOutcome {
        .error(.notFound, message: "unknown label(s): \(missing.joined(separator: ", ")); omit strictLabels to create them",
               data: ["unknownLabels": missing.joined(separator: ",")])
    }
}
#endif
