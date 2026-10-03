// Kronos/Intents/KronosEntities.swift. AppIntents entities so Shortcuts can pick a task or
// project by name, and so intent parameters resolve to something the Shortcuts app can
// display and search. Read-only projections; every mutation still goes through
// `TaskStoring` from AppIntentsKronos.swift, never from here.

import AppIntents
import CoreSpotlight
import KronosCore

struct TaskEntity: AppEntity {
    let id: UUID

    // Properties Shortcuts can read, filter and sort on. Titles are bare literals for the same reason
    // as the type name below.
    @Property(title: LocalizedStringResource("Title"))
    var title: String
    @Property(title: LocalizedStringResource("Project"))
    var projectName: String?
    @Property(title: LocalizedStringResource("Due Date"))
    var dueDate: Date?
    @Property(title: LocalizedStringResource("Notes"))
    var notes: String
    @Property(title: LocalizedStringResource("Completed"))
    var isCompleted: Bool
    /// 0 = none, 1 = low, 2 = medium, 3 = high, 4 = urgent (`KPriority.rawValue`).
    @Property(title: LocalizedStringResource("Priority"))
    var priority: Int

    // GAP: stays a bare literal, not a Localizable.xcstrings key — see KronosIntentEnums.swift's
    // note on why AppIntents' own metadata processor rejects a LocalizedStringResource pointed
    // at our hand-rolled catalog.
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Task"
    static var defaultQuery = TaskEntityQuery()

    init(id: UUID, title: String, projectName: String?, dueDate: Date? = nil, notes: String = "",
         isCompleted: Bool = false, priority: Int = 0) {
        self.id = id
        self.title = title
        self.projectName = projectName
        self.dueDate = dueDate
        self.notes = notes
        self.isCompleted = isCompleted
        self.priority = priority
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)",
                              subtitle: projectName.map { "\($0)" })
    }
}

extension TaskEntity {
    /// The projection of one stored task. Read-only: nothing here writes back.
    @MainActor
    init(_ task: KTask) {
        self.init(id: task.id, title: task.title, projectName: task.project?.name,
                  dueDate: task.dueDay.map { Day.date($0, calendar: KronosLocale.calendar) },
                  notes: task.notes, isCompleted: !KStatus.open.contains(task.status),
                  priority: task.priorityRaw)
    }
}

/// Lets the system index tasks as Spotlight items that open the matching entity. Kronos's own Spotlight
/// indexer (Kronos/Spotlight) stays the one that decides what is indexed and when; this only describes how
/// one task looks as an entity, so a Shortcuts or Siri result for a task carries the same facts.
@available(macOS 15.0, *)
extension TaskEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let set = defaultAttributeSet
        set.title = title
        set.contentDescription = notes.isEmpty ? projectName : notes
        set.dueDate = dueDate
        return set
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

    @MainActor
    private func entity(_ t: KTask) -> TaskEntity { TaskEntity(t) }
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
