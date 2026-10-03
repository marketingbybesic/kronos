// Kronos/List/ListCompletion.swift
// Shared completion logic for the status circle click, Space key and context-menu
// "Complete" — todo <-> done toggle, no confirmation, 5 s undo. The status circle never
// cycles, and subtask-first completion is a Bar-only rule that does not apply to the list
// row. Posts to the shell-level `UndoToastCenter` (KUndoPill.swift) rather than a local
// `@State`, so the same pill shows regardless of which screen completed the task.
//
// Completion hands off to what comes next: the pill reads "Done. Next: <first move>" and
// Return (the pill's primary action) starts that task, in progress and pinned. "Next" is the
// first eligible row of the list being shown, the pin first (NextEligibility). The completed
// row stays struck through for about a second (ListLinger) before it leaves.
import SwiftUI
import KronosCore

@MainActor
enum ListCompletion {
    static func toggle(_ task: KTask, store: TaskStoring, model: AppModel) {
        if task.status == .done {
            ListLinger.release(task.id)
            store.reopen(task.id)
            model.commit(String(format: String(localized: "undo.uncompleted.name"), task.title))
        } else {
            // Computed BEFORE the write: once the row is done it may leave the list, and the
            // selection (and keyboard focus) must land on a neighbour, not on nothing (audit D11).
            let next = model.selectedTaskID == task.id ? neighbourToSelect(after: task.id, model: model) : nil
            store.complete(task.id)
            ListLinger.hold(task.id, in: model.scope, model: model)
            if let next { model.selectedTaskID = next }
            model.didMutate()   // pill: showCompletionPill below (Done. Next, with Start)
            if next != nil { NotificationCenter.default.post(name: Notification.Name("kronosFocusListRequested"), object: nil) }
            showCompletionPill(for: task, model: model)
        }
    }

    /// "Done. Next: <first move>" with Start as the primary action when the shown list has an
    /// eligible next task; the plain "Completed" pill otherwise.
    static func showCompletionPill(for task: KTask, model: AppModel) {
        guard let target = handoffTarget(after: task.id, model: model) else {
            UndoToastCenter.shared.show(String(format: String(localized: "undo.completed.name"), task.title))
            return
        }
        let move = FirstMoveLogic.text(for: target) ?? target.title
        let targetID = target.id
        UndoToastCenter.shared.show(String(format: String(localized: "undo.donenext"), move),
                                    primaryTitle: String(localized: "undo.donenext.start"),
                                    onPrimary: { start(targetID, model: model) })
    }

    /// The task the completion hands off to: the pin when it is still open, else the first
    /// eligible row of the list being shown (done, pending review, blocked and archived skipped).
    static func handoffTarget(after completedID: UUID, model: AppModel) -> KTask? {
        let rows = ListContext(model: model).rows
        let pick = NextEligibility.pick(pinned: model.pinnedFocusTaskID, rows: rows, lookup: model.store.allTasks())
        return pick?.id == completedID ? nil : pick
    }

    /// Start: the task goes in progress and becomes the pinned focus, and the list selects it.
    /// Nothing is written when it is already in progress.
    static func start(_ id: UUID, model: AppModel) {
        guard let task = model.store.task(id), KStatus.open.contains(task.status) else { return }
        if task.status != .inProgress { model.store.setStatus(id, .inProgress) }
        model.pinnedFocusTaskID = id
        if ListContext(model: model).rows.contains(where: { $0.id == id }) { model.selectedTaskID = id }
        model.didMutate()   // pill: this IS the pill's Start action; a second pill would only repeat it
    }

    /// The cue a finished task earns: a parent with children gets the parent cue, everything
    /// else the task cue. For the completion observer (AppDelegate), which receives the task id.
    static func cue(forCompleted id: UUID, store: TaskStore) -> KronosSounds.Cue {
        let children = store.task(id)?.orderedChildren.count ?? 0
        return CompletionCueRule.isParentFinish(childCount: children) ? .parent : .task
    }

    /// The next open row below `id`, else the nearest open row above it, else nil.
    static func neighbourToSelect(after id: UUID, model: AppModel) -> UUID? {
        let rows = ListContext(model: model).rows
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return nil }
        let open: (KTask) -> Bool = { KStatus.open.contains($0.status) }
        return rows[(i + 1)...].first(where: open)?.id ?? rows[..<i].last(where: open)?.id
    }
}
