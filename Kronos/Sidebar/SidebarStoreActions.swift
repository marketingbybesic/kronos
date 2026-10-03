// Kronos/Sidebar/SidebarStoreActions.swift
// The store writes behind the sidebar's project and area menus and its drop targets, kept free of
// SwiftUI so the live test and the self-tests drive the exact code the menus call. Every action is
// ONE undo step and a no-op (no step, no pill) when nothing would change.
import Foundation
import KronosCore

@MainActor
enum SidebarStoreActions {

    // MARK: Archive a project

    struct ArchiveOutcome: Equatable {
        var name: String
        /// Open top-level tasks of the project, which leave every list but the project's own.
        var hiddenOpenTasks: Int
    }

    /// Archives a live project. Nil (nothing written) for an unknown or already archived one.
    static func archiveProject(_ id: UUID, store: TaskStore) -> ArchiveOutcome? {
        guard let project = store.allProjects().first(where: { $0.id == id }) else { return nil }
        let hidden = store.allTasks().filter { $0.projectID == id && KStatus.open.contains($0.status) }.count
        store.archiveProject(id)
        return ArchiveOutcome(name: project.name, hiddenOpenTasks: hidden)
    }

    // MARK: Delete an area

    struct AreaDeleteOutcome: Equatable {
        var name: String
        /// Projects that were in the area and now stand on their own.
        var releasedProjects: Int
    }

    /// Deletes an area; its projects (archived ones too) become area-less. One undo step.
    static func deleteArea(_ id: UUID, store: TaskStore) -> AreaDeleteOutcome? {
        guard let area = store.allAreas().first(where: { $0.id == id }) else { return nil }
        let name = area.name
        let projects = store.allProjects(includeArchived: true).filter { $0.area?.id == id }
        var deleted = false
        store.groupedUndo("Delete Area") {
            for project in projects { store.moveProject(project.id, toArea: nil) }
            deleted = (try? store.deleteArea(area)) != nil
        }
        guard deleted else {
            // A refused delete must not leave the projects moved out.
            if !projects.isEmpty { store.undo() }
            return nil
        }
        return AreaDeleteOutcome(name: name, releasedProjects: projects.count)
    }

    // MARK: Drop a task row on a project

    enum MoveOutcome: Equatable {
        case moved(projectName: String)
        case alreadyThere
        case refused      // a step (child task), an unknown row, or an archived/unknown project
    }

    /// Files a dragged task row into `projectID`. A task keeps its steps; a step is refused (it
    /// follows its parent's project).
    static func moveTask(_ taskID: UUID, toProject projectID: UUID, store: TaskStore) -> MoveOutcome {
        guard let task = store.task(taskID), !task.isSubtask,
              let project = store.allProjects().first(where: { $0.id == projectID }) else { return .refused }
        guard task.projectID != projectID else { return .alreadyThere }
        store.move(taskID, toProject: project)
        return .moved(projectName: project.name)
    }
}
