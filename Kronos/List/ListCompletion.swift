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
            // Computed BEFORE the write: once the row is done it may leave the list, and the
            // selection (and keyboard focus) must land on a neighbour, not on nothing (audit D11).
            let next = model.selectedTaskID == task.id ? neighbourToSelect(after: task.id, model: model) : nil
            store.complete(task.id)
            if let next { model.selectedTaskID = next }
            model.didMutate()
            if next != nil { NotificationCenter.default.post(name: Notification.Name("kronosFocusListRequested"), object: nil) }
            UndoToastCenter.shared.show(String(format: String(localized: "undo.completed.name"), task.title))
        }
    }

    /// The next open row below `id`, else the nearest open row above it, else nil.
    static func neighbourToSelect(after id: UUID, model: AppModel) -> UUID? {
        let rows = ListContext(model: model).rows
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return nil }
        let open: (KTask) -> Bool = { KStatus.open.contains($0.status) }
        return rows[(i + 1)...].first(where: open)?.id ?? rows[..<i].last(where: open)?.id
    }
}
