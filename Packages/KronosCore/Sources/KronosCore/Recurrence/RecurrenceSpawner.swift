// `TaskStore.complete(_:)` calls `spawnNext` from inside a `groupedUndo("Complete")`
// block, so the completion and the spawn collapse into ONE undo step without this file
// knowing anything about stack shape. `spawnNext` therefore pushes an ordinary,
// self-contained undo step for the row it creates; grouping is the caller's concern.

import Foundation
import SwiftData

/// Creates the next occurrence of a recurring task on completion
/// (data-model.md §6.3's field-copy rules) and merges that creation into the
/// same undo step as the completion that triggered it.
@MainActor
public enum RecurrenceSpawner {

    /// Spawns the next instance of `taskID`'s series, if it has one.
    ///
    /// Returns the new `KTask`, or nil when the task has no `recurrenceRule`,
    /// the rule fails to parse, or the task no longer exists. Safe to call
    /// unconditionally after any completion — non-recurring tasks are a
    /// no-op. Call this only once per completion (the integration note's
    /// `wasOpen` guard prevents a redundant `complete` on an already-done
    /// task from spawning a second sibling).
    @discardableResult
    public static func spawnNext(for taskID: UUID, completedOn: Int, in store: TaskStore) -> KTask? {
        guard let source = store.taskIncludingDeleted(taskID),
              let ruleString = source.recurrenceRule,
              let rule = RecurrenceRule.parse(ruleString),
              let dueDay = source.dueDay
        else { return nil }

        let nextDue = RecurrenceEngine.nextDueDay(after: dueDay, rule: rule, completedOn: completedOn)
        let seriesID = source.seriesID ?? source.id

        let next = KTask(title: source.title, notes: source.notes, project: source.project)
        next.firstMove          = source.firstMove
        next.priorityRaw        = source.priorityRaw
        next.depthRaw           = source.depthRaw
        next.dread              = source.dread
        next.energyKindRaw      = source.energyKindRaw
        next.estimateMinutes    = source.estimateMinutes
        next.effortRaw          = source.effortRaw
        next.labels             = source.labels
        next.recurrenceRule     = ruleString
        next.seriesID           = seriesID
        next.triagedAt          = source.triagedAt
        next.triageModel        = source.triageModel
        next.triageRationale    = source.triageRationale
        next.needsTriage        = false

        // fresh per data-model §6.3: new id/timestamps, open+unstarted status
        // (KTask's own initializer default, left untouched here), un-ordo'd,
        // no completion/calendar/triage-review carried from the old instance.
        next.dueDay        = nextDue
        next.originalDueDay = nextDue
        next.ordoIndex     = nil
        next.completedAt   = nil
        next.calendarEventID = nil

        // Ensure the source itself carries a seriesID from here on (first
        // time recurrence produces a sibling for it).
        if source.seriesID == nil { source.seriesID = seriesID }

        next.sortIndex = store.appendIndex(scope: .tasksGlobal)
        store.context.insert(next)

        for s in source.orderedSubtasks {
            let copy = KSubtask(title: s.title, sortIndex: s.sortIndex)
            copy.isDone = false
            copy.task = next
            store.context.insert(copy)
        }

        store.saveContext()
        // One ordinary undo step for the row we created. When `complete(_:)`
        // called us we are inside its `groupedUndo` block, so this collapses
        // into the completion's single step; called directly (as a test may),
        // the spawn is undoable on its own. Either way this file no longer
        // knows anything about the undo stack's shape.
        store.pushSoftDeleteUndoStep("Repeat Task", next)
        return next
    }
}
