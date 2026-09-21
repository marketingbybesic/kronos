// Kronos/List/ListCompletion.swift
// Shared completion logic for the status circle click, Space key and context-menu
// "Complete" — todo <-> done toggle, no confirmation, 5 s undo. The status circle never
// cycles, and subtask-first completion is a Bar-only rule that does not apply to the list
// row. Posts to the
// shell-level `UndoToastCenter` (KUndoPill.swift) rather than a local `@State`, so the same
// pill shows regardless of which screen completed the task.
import SwiftUI
import KronosCore

@MainActor
enum ListCompletion {
    static func toggle(_ task: KTask, store: TaskStoring, model: AppModel) {
        if task.status == .done {
            store.reopen(task.id)
            model.didMutate()
            UndoToastCenter.shared.show(String(format: String(localized: "undo.uncompleted.name"), task.title))
        } else {
            store.complete(task.id)
            model.didMutate()
            UndoToastCenter.shared.show(String(format: String(localized: "undo.completed.name"), task.title))
        }
    }
}
