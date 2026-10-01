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

@MainActor
enum FocusFilterState {
    static let defaultsKey = "kronos.focusfilter.projectID"
    private static var observer: NSObjectProtocol?
    /// The list the user was on before the Focus took over; nil while no Focus filter is active.
    private static var previousScope: ListScope?
    private static var appliedProject: UUID?

    static var activeProjectID: UUID? {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(UUID.init(uuidString:))
    }

    static func publish(projectID: UUID?) {
        if let projectID { UserDefaults.standard.set(projectID.uuidString, forKey: defaultsKey) }
        else { UserDefaults.standard.removeObject(forKey: defaultsKey) }
        NotificationCenter.default.post(name: .kronosFocusFilterChanged, object: nil)
    }

    /// Called once from `KronosIntents.bootstrap`. The notification observer applies the filter to the shell.
    static func install(model: AppModel) {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .kronosFocusFilterChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { apply(model: model) }
        }
    }

    private static func apply(model: AppModel) {
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
