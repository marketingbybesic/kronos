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
                            ordoIndex: t.ordoIndex, projectName: t.project?.name,
                            notes: t.notes)
        }
    }

    /// The text goes through the same grammar as every other add field (`EntryText.plan`:
    /// outline subtasks, multi-word `#project` or `#area`, `@label`, priority, effort, dates).
    /// `projectName` (an intent parameter) is matched with the same matcher and is only a
    /// default: a `#token` in the text wins. Returns the first created task.
    func intentCreateTask(title: String, projectName: String?, priorityRaw: Int, dueDay: Int?) -> UUID {
        let today = Day.today(calendar: KronosLocale.calendar)
        let plans = EntryText.intentPlans(text: title, projectName: projectName, priorityRaw: priorityRaw,
                                          dueDay: dueDay, directory: store.entryDirectory(), today: today)
        let made = store.createTasks(from: plans, undoName: String(localized: "undo.quickadd"))
        return made.first?.id ?? UUID()
    }

    /// The title fields as above, plus notes and a web link written onto the new task inside the SAME undo
    /// step (one Cmd-Z removes the whole task). The link becomes a link:// line in the notes, the form the
    /// inspector's Links section reads.
    func intentCreateTask(_ request: IntentNewTask) -> UUID {
        var id = UUID()
        store.groupedUndo(String(localized: "undo.quickadd")) {
            id = intentCreateTask(title: request.title, projectName: request.projectName,
                                  priorityRaw: request.priorityRaw, dueDay: request.dueDay)
            guard request.notes != nil || request.link != nil, store.task(id) != nil else { return }
            var text = request.notes ?? ""
            if let raw = request.link, let web = LinkInput.pastedURL(raw) {
                text = ContextLink(kind: .web, reference: web.reference, displayName: web.label).appending(to: text)
            }
            store.update(id) { $0.notes = text }
        }
        return id
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
