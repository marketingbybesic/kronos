// Kronos/Intents/IntentStoreAdapter.swift
//
// Bridges the pure `IntentActions` protocols (IntentActions.swift, Foundation-only) onto
// the real `TaskStoring` + `AppModel`. Every write still goes through `TaskStoring`, so
// undo, `.kronosTaskDidCreate` (auto-triage) and the completion sound all fire exactly as
// they do from the UI.

import Foundation
import KronosCore

/// Wraps one `TaskStoring` + the ranking/day inputs an intent needs. A struct, not a
/// class: it holds no state of its own, just forwards to the store.
@MainActor
struct TaskStoringIntentAdapter: IntentTaskStore {
    let store: any TaskStoring
    let language: Lang

    func intentAllOpenTasks() -> [IntentTaskFacts<UUID>] {
        store.allTasks().map { t in
            IntentTaskFacts(id: t.id, title: t.title,
                            isOpen: KStatus.open.contains(t.status),
                            priority: t.priorityRaw, dueDay: t.dueDay,
                            ordoIndex: t.ordoIndex, projectName: t.project?.name)
        }
    }

    func intentCreateTask(title: String, projectName: String?, priorityRaw: Int, dueDay: Int?) -> UUID {
        let today = Day.today(calendar: KronosLocale.calendar)
        let parsed = QuickAddParser().parse(title, projects: store.allProjects().map(\.name), today: today)
        let project = parsed.projectName.flatMap { name in store.allProjects().first { $0.name == name } }
        let priority = parsed.priority != .none ? parsed.priority : (KPriority(rawValue: priorityRaw) ?? .none)
        let due = parsed.dueDay ?? dueDay
        let task = store.create(title: parsed.title.isEmpty ? title : parsed.title, notes: "",
                                project: project, status: .todo, priority: priority, dueDay: due)
        if let effort = parsed.effort { store.setEffort(task.id, effort) }
        if let labelName = parsed.labelName { store.addLabel(store.label(named: labelName), to: task.id) }
        return task.id
    }

    func intentComplete(_ id: UUID) { store.complete(id) }

    func intentFirstMove(for id: UUID) -> String? {
        guard let task = store.task(id) else { return nil }
        if let stored = task.firstMove, !stored.isEmpty { return stored }
        return DeterministicFirstMove.generate(title: task.title, firstMoveURL: nil,
                                               hasOpenSubtask: task.nextOpenSubtask != nil,
                                               notesNonEmpty: !task.notes.isEmpty,
                                               dread: task.dread, language: language)
    }
}

/// Wraps `AppModel`'s focus fields on the main actor. Intents run their store work inside
/// `MainActor.run` (AppIntentsKronos.swift) so this initializer is never called off-actor.
@MainActor
struct AppModelIntentAdapter: IntentFocusModel {
    let model: AppModel
    var intentFocusTaskID: UUID? { model.focusTaskID }
    func intentSetPinnedFocus(_ id: UUID?) {
        model.pinnedFocusTaskID = id
        model.didMutate()
    }
}
