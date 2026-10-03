// Kronos/Intents/KronosFocusFilter.swift
// System Focus filter: in System Settings > Focus > (a Focus) > Focus Filters > Kronos the user picks a
// project. While that Focus is on, Kronos opens that project's list on its own ("Focus this project"),
// and puts the previous list back when the Focus ends. No notifications, no developer program.
//
// The system runs `perform()` when the Focus turns on (with the chosen project) and again when it turns
// off (with an empty filter), so `project == nil` means "Focus ended".
// Intent metadata strings stay bare literals: the metadata processor does not read our catalog (see
// KronosIntentEnums.swift).
import AppIntents
import AppKit
import KronosCore

extension Notification.Name {
    /// Posted (main thread) whenever the Focus filter publishes a new project or clears it.
    static let kronosFocusFilterChanged = Notification.Name("kronosFocusFilterChanged")
}

struct KronosFocusFilter: SetFocusFilterIntent {
    static var title: LocalizedStringResource = "Focus on a project"
    static var description: IntentDescription? = IntentDescription("Open one project in Kronos while this Focus is on.")

    @Parameter(title: LocalizedStringResource("Project"))
    var project: ProjectEntity?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: project?.name ?? "Kronos"))
    }

    func perform() async throws -> some IntentResult {
        let id = project?.id
        await MainActor.run { FocusFilterState.publish(projectID: id) }
        return .result()
    }
}

/// What a running Focus filter has to remember across a relaunch: the list the person was on
/// before the Focus took over and the project it opened. Without it a restart during the Focus
/// would forget where to go back to.
struct FocusFilterMemory {
    let defaults: UserDefaults
    static let previousKey = "kronos.focusfilter.previousScope"
    static let appliedKey = "kronos.focusfilter.appliedProject"

    var previousScope: ListScope? {
        get { defaults.data(forKey: Self.previousKey).flatMap { try? JSONDecoder().decode(ListScope.self, from: $0) } }
        nonmutating set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: Self.previousKey) }
            else { defaults.removeObject(forKey: Self.previousKey) }
        }
    }

    var appliedProject: UUID? {
        get { defaults.string(forKey: Self.appliedKey).flatMap(UUID.init(uuidString:)) }
        nonmutating set {
            if let newValue { defaults.set(newValue.uuidString, forKey: Self.appliedKey) }
            else { defaults.removeObject(forKey: Self.appliedKey) }
        }
    }
}

@MainActor
enum FocusFilterState {
    static let defaultsKey = "kronos.focusfilter.projectID"
    private static var observer: NSObjectProtocol?
    /// Persisted (FocusFilterMemory): the list the user was on before the Focus took over; nil
    /// while no Focus filter is active.
    static var memory = FocusFilterMemory(defaults: KronosEnv.defaults)
    private static var previousScope: ListScope? {
        get { memory.previousScope }
        set { memory.previousScope = newValue }
    }
    private static var appliedProject: UUID? {
        get { memory.appliedProject }
        set { memory.appliedProject = newValue }
    }

    static var activeProjectID: UUID? {
        KronosEnv.defaults.string(forKey: defaultsKey).flatMap(UUID.init(uuidString:))
    }

    static func publish(projectID: UUID?) {
        if let projectID { KronosEnv.defaults.set(projectID.uuidString, forKey: defaultsKey) }
        else { KronosEnv.defaults.removeObject(forKey: defaultsKey) }
        NotificationCenter.default.post(name: .kronosFocusFilterChanged, object: nil)
    }

    /// Called once from `KronosIntents.bootstrap`. The notification observer applies the filter to the shell.
    static func install(model: AppModel) {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .kronosFocusFilterChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { apply(model: model) }
        }
        // A Focus that is still on from before this launch applies again; the remembered list
        // is what it returns to afterwards.
        apply(model: model)
    }

    /// Applies the current filter state to the shell; also what a test calls after `publish`.
    static func apply(model: AppModel) {
        if let id = activeProjectID, model.store.allProjects().contains(where: { $0.id == id }) {
            if previousScope == nil { previousScope = model.scope }
            model.scope = .project(id)
            appliedProject = id
        } else if let back = previousScope {
            // Only restore when the user is still looking at the Focus list; if they moved on, leave them be.
            if case .project(let current) = model.scope, current == appliedProject {
                model.scope = back
            }
            previousScope = nil
            appliedProject = nil
        }
    }
}
