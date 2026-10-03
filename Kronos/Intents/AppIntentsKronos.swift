// Kronos/Intents/AppIntentsKronos.swift
//
// The App Intents. Each one is a thin `perform()` that resolves `AppDelegate.shared`
// (the intent runs in-process; macOS launches the app headless first if it was not already
// running, since Kronos is not sandboxed and declares no separate intents extension) and
// hands off to `IntentActions`, so the tested logic and the live logic are the same code.
// Every store write goes through `TaskStoring` — undo, `.kronosTaskDidCreate` (auto-triage)
// and the completion sound all fire exactly as they do from the UI.

import AppIntents
import AppKit
import KronosCore

/// Shared failure when the app has not finished launching yet (should not happen once
/// `KronosIntents.bootstrap` has run once, but every intent checks rather than force-unwrap).
@MainActor
private func requireModel() throws -> AppModel {
    guard let model = AppDelegate.shared?.model else {
        throw KronosIntentError.appNotReady
    }
    return model
}

enum KronosIntentError: Error, CustomLocalizedStringResourceConvertible {
    case appNotReady
    case emptyTitle
    case noFocusTask
    case taskNotFound
    case taskAlreadyDone

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appNotReady: return "Kronos is still starting up."
        case .emptyTitle: return "That task has no text."
        case .noFocusTask: return "Nothing is in focus right now."
        case .taskNotFound: return "That task is no longer in Kronos."
        case .taskAlreadyDone: return "That task is already done."
        }
    }
}

// MARK: - AddTask

struct AddTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Add a Task"
    static var description = IntentDescription("Adds a task to Kronos using the same quick-add syntax as the app (#project, @label, !priority, ~effort, a date), with optional notes, due date and link.")

    // GAP: stays "Task", a bare literal — AppIntents' own metadata processor rejects a
    // LocalizedStringResource pointed at our hand-rolled catalog (see KronosIntentEnums.swift's
    // note).
    @Parameter(title: "Task")
    var text: String

    // Optional default destination, matched with the same matcher as `#project` in the text.
    @Parameter(title: "Project")
    var project: String?

    @Parameter(title: "Notes")
    var notes: String?

    // A date the task is due; a `!date` or "tomorrow" typed in the text is parsed too and wins.
    @Parameter(title: LocalizedStringResource("Due Date"), kind: .date)
    var due: Date?

    @Parameter(title: LocalizedStringResource("Link"))
    var url: URL?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<TaskEntity> & ProvidesDialog {
        let model = try requireModel()
        let adapter = TaskStoringIntentAdapter(store: model.store, language: appLanguage())
        let request = IntentNewTask(title: text, projectName: project, priorityRaw: KPriority.none.rawValue,
                                    dueDay: due.map { Day.from($0, calendar: KronosLocale.calendar) },
                                    notes: notes, link: url?.absoluteString)
        guard let result = IntentActions.addTask(store: adapter, request: request)
        else { throw KronosIntentError.emptyTitle }
        model.didMutate()
        guard let task = model.store.task(result.id) else { throw KronosIntentError.emptyTitle }
        return .result(value: TaskEntity(task), dialog: IntentDialog(stringLiteral: result.confirmation))
    }
}

// MARK: - CompleteTask

struct CompleteTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Complete a Task"
    static var description = IntentDescription("Completes the chosen task, with undo and the completion sound like in the app. A recurring task schedules its next instance.")

    @Parameter(title: "Task")
    var task: TaskEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try requireModel()
        guard model.store.task(task.id) != nil else { throw KronosIntentError.taskNotFound }
        let adapter = TaskStoringIntentAdapter(store: model.store, language: appLanguage())
        guard let title = IntentActions.completeTask(store: adapter, id: task.id) else {
            throw KronosIntentError.taskAlreadyDone
        }
        model.didMutate()
        return .result(dialog: IntentDialog(stringLiteral: String(format: String(localized: "intents.complete.done"), title)))
    }
}

// MARK: - OpenTask

struct OpenTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Open a Task"
    static var description = IntentDescription("Opens the chosen task in the Kronos window.")
    static var openAppWhenRun = true

    @Parameter(title: "Task")
    var task: TaskEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try requireModel()
        guard model.openTaskByID(task.id) else { throw KronosIntentError.taskNotFound }
        NSApp.activate(ignoringOtherApps: true)
        return .result()
    }
}

// MARK: - FindTasks

struct FindTasksIntent: AppIntent {
    static var title: LocalizedStringResource = "Find Tasks"
    static var description = IntentDescription("Finds tasks by text, project or due date. Open tasks come first, in the Up next order.")

    @Parameter(title: LocalizedStringResource("Text"))
    var text: String?

    @Parameter(title: "Project")
    var project: ProjectEntity?

    @Parameter(title: LocalizedStringResource("Due On or Before"), kind: .date)
    var dueBy: Date?

    @Parameter(title: LocalizedStringResource("Include Completed"), default: false)
    var includeCompleted: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[TaskEntity]> & ProvidesDialog {
        let model = try requireModel()
        let adapter = TaskStoringIntentAdapter(store: model.store, language: appLanguage())
        let facts = IntentActions.findTasks(store: adapter, text: text, projectName: project?.name,
                                            dueOnOrBefore: dueBy.map { Day.from($0, calendar: KronosLocale.calendar) },
                                            includeCompleted: includeCompleted, limit: 50)
        let found = facts.compactMap { model.store.task($0.id) }.map { TaskEntity($0) }
        let line = found.isEmpty
            ? String(localized: "intents.find.none")
            : String(format: String(localized: "intents.find.count"), found.count)
        return .result(value: found, dialog: IntentDialog(stringLiteral: line))
    }
}

// MARK: - WhatsNext

struct WhatsNextIntent: AppIntent {
    static var title: LocalizedStringResource = "What's Next"
    static var description = IntentDescription("Speaks the focus task's first move, or a calm line when nothing is open.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try requireModel()
        let adapter = TaskStoringIntentAdapter(store: model.store, language: appLanguage())
        let focus = AppModelIntentAdapter(model: model)
        let line = IntentActions.whatsNext(store: adapter, focus: focus,
                                           fallbackTitle: String(localized: "impuls.title"),
                                           calmEmptySentence: String(localized: "empty.today.body"))
        return .result(dialog: IntentDialog(stringLiteral: line))
    }
}

// MARK: - CompleteCurrentTask

struct CompleteCurrentTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Complete Current Task"
    static var description = IntentDescription("Completes the task currently in focus in Kronos.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try requireModel()
        let adapter = TaskStoringIntentAdapter(store: model.store, language: appLanguage())
        let focus = AppModelIntentAdapter(model: model)
        guard let title = IntentActions.completeCurrentTask(store: adapter, focus: focus) else {
            throw KronosIntentError.noFocusTask
        }
        model.didMutate()
        return .result(dialog: IntentDialog(stringLiteral: title))
    }
}

// MARK: - CaptureNotes

struct CaptureNotesIntent: AppIntent {
    static var title: LocalizedStringResource = "Capture Notes"
    static var description = IntentDescription("Opens Kronos's Capture review so pasted notes can be turned into tasks.")
    static var openAppWhenRun = true

    @Parameter(title: "Notes")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try requireModel()
        // AppModel.openCapture(with:) is the seam: Capture reads the text once.
        NSApp.activate(ignoringOtherApps: true)
        model.openCapture(with: text)
        return .result()
    }
}

// MARK: - Switch Up next preset (SwitchOrdoPreset)

struct SwitchOrdoPresetIntent: AppIntent {
    static var title: LocalizedStringResource = "Switch Up Next Preset"
    static var description = IntentDescription("Switches the current list's Up next preset (Deadline, Quick Wins, Focused Work, Priority or Coach).")

    @Parameter(title: "Preset")
    var preset: OrdoPresetOption

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try requireModel()
        model.coach.applyPreset(preset.presetID, to: model.scope)
        // preset.spokenName resolves the same "ordo.preset.*" catalog keys OrdoPreset.name
        // uses, so the dialog follows the app language.
        return .result(dialog: IntentDialog(stringLiteral: preset.spokenName))
    }
}

// MARK: - Pick one (StartImpuls)

struct StartImpulsIntent: AppIntent {
    static var title: LocalizedStringResource = "Pick One"
    static var description = IntentDescription("Opens Pick one, Kronos's one-question energy picker, at the given energy level.")
    static var openAppWhenRun = true

    @Parameter(title: "Energy", default: .mid)
    var energy: EnergyOption

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try requireModel()
        // ImpulsEnergyMemory (Kronos/Impuls/ImpulsCandidate.swift) is what ImpulsScreen reads
        // on `.onAppear` to preselect the energy row; writing it here means the screen opens
        // already on the energy Shortcuts asked for, with no seam change needed.
        ImpulsEnergyMemory.rememberToday(energy.coreValue)
        NSApp.activate(ignoringOtherApps: true)
        model.isImpulsOpen = true
        return .result()
    }
}

// MARK: - PinFocus

struct PinFocusIntent: AppIntent {
    static var title: LocalizedStringResource = "Pin Focus Task"
    static var description = IntentDescription("Pins a task as the focus task in Kronos, the same as pressing F on it.")

    @Parameter(title: "Task")
    var task: TaskEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try requireModel()
        let focus = AppModelIntentAdapter(model: model)
        IntentActions.pinFocus(focus: focus, taskID: task.id)
        return .result(dialog: IntentDialog(stringLiteral: task.title))
    }
}

@MainActor
private func appLanguage() -> Lang { Lang(rawValue: KronosLocale.languageCode) ?? .en }
