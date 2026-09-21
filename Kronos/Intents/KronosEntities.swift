// Kronos/Intents/KronosEntities.swift. AppIntents entities so Shortcuts can pick a task or
// project by name, and so intent parameters resolve to something the Shortcuts app can
// display and search. Read-only projections; every mutation still goes through
// `TaskStoring` from AppIntentsKronos.swift, never from here.

import AppIntents
import KronosCore

struct TaskEntity: AppEntity {
    let id: UUID
    let title: String
    let projectName: String?

    // GAP: stays a bare literal, not a Localizable.xcstrings key — see KronosIntentEnums.swift's
    // note on why AppIntents' own metadata processor rejects a LocalizedStringResource pointed
    // at our hand-rolled catalog.
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Task"
    static var defaultQuery = TaskEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)",
                              subtitle: projectName.map { "\($0)" })
    }
}

struct TaskEntityQuery: EntityQuery, EntityStringQuery {
    @MainActor
    func entities(for identifiers: [TaskEntity.ID]) async throws -> [TaskEntity] {
        guard let model = AppDelegate.shared?.model else { return [] }
        let ids = Set(identifiers)
        return openTasks(model).filter { ids.contains($0.id) }.map(entity)
    }

    @MainActor
    func entities(matching string: String) async throws -> [TaskEntity] {
        guard let model = AppDelegate.shared?.model else { return [] }
        let folded = KTextFold.fold(string)
        return openTasks(model)
            .filter { folded.isEmpty || KTextFold.fold($0.title).contains(folded) }
            .prefix(25)
            .map(entity)
    }

    @MainActor
    func suggestedEntities() async throws -> [TaskEntity] {
        guard let model = AppDelegate.shared?.model else { return [] }
        return Array(openTasks(model).prefix(10)).map(entity)
    }

    @MainActor
    private func openTasks(_ model: AppModel) -> [KTask] {
        model.store.allTasks().filter { KStatus.open.contains($0.status) }
    }

    private func entity(_ t: KTask) -> TaskEntity {
        TaskEntity(id: t.id, title: t.title, projectName: t.project?.name)
    }
}

struct ProjectEntity: AppEntity {
    let id: UUID
    let name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Project"
    static var defaultQuery = ProjectEntityQuery()

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct ProjectEntityQuery: EntityQuery, EntityStringQuery {
    @MainActor
    func entities(for identifiers: [ProjectEntity.ID]) async throws -> [ProjectEntity] {
        guard let model = AppDelegate.shared?.model else { return [] }
        let ids = Set(identifiers)
        return model.store.allProjects().filter { ids.contains($0.id) }.map { ProjectEntity(id: $0.id, name: $0.name) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [ProjectEntity] {
        guard let model = AppDelegate.shared?.model else { return [] }
        let folded = KTextFold.fold(string)
        return model.store.allProjects()
            .filter { folded.isEmpty || KTextFold.fold($0.name).contains(folded) }
            .prefix(25)
            .map { ProjectEntity(id: $0.id, name: $0.name) }
    }

    @MainActor
    func suggestedEntities() async throws -> [ProjectEntity] {
        guard let model = AppDelegate.shared?.model else { return [] }
        return model.store.allProjects().prefix(10).map { ProjectEntity(id: $0.id, name: $0.name) }
    }
}
