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
    /// The next instance's id is `RecurrenceIdentity.instanceID(seriesID:dueDay:)`, the same on
    /// every device and every context. When a live row with that id already exists (another
    /// context or device completed this instance first), nothing is created and nil is returned.
    /// A hidden row with that id (an undone completion) is shown again and refreshed instead of
    /// adding a second row with the same id.
    ///
    /// Returns the new (or revived) `KTask`, or nil when the task has no `recurrenceRule`, the
    /// rule fails to parse, the task no longer exists, or the next instance already exists.
    /// Call this only once per completion (the integration note's `wasOpen` guard prevents a
    /// redundant `complete` on an already-done task from reaching here).
    @discardableResult
    public static func spawnNext(for taskID: UUID, completedOn: Int, in store: TaskStore) -> KTask? {
        guard let source = store.taskIncludingDeleted(taskID),
              let ruleString = source.recurrenceRule,
              let rule = RecurrenceRule.parse(ruleString),
              let dueDay = source.dueDay
        else { return nil }

        let nextDue = RecurrenceEngine.nextDueDay(after: dueDay, rule: rule, completedOn: completedOn)
        let seriesID = source.seriesID ?? source.id
        let nextID = RecurrenceIdentity.instanceID(seriesID: seriesID, dueDay: nextDue)

        // Ensure the source itself carries a seriesID from here on (first
        // time recurrence produces a sibling for it).
        if source.seriesID == nil { source.seriesID = seriesID }

        let existing = store.taskIncludingDeleted(nextID)
        if let existing, existing.deletedAt == nil {
            // Already spawned by the other side: one instance, not two.
            store.saveContext()
            return nil
        }

        let next: KTask
        if let existing {
            next = existing
            next.deletedAt = nil
            next.statusRaw = KStatus.todo.rawValue
            next.title = source.title
            next.notes = source.notes
            if next.project !== source.project { next.project = source.project }
            next.projectID = source.project?.id
            next.areaID = source.project?.area?.id
            next.isProjectArchived = source.project?.isArchived ?? false
        } else {
            next = KTask(title: source.title, notes: source.notes, project: source.project)
            next.id = nextID
        }
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
        next.updatedAt     = Date()

        // A recurring SUBTASK regenerates as a subtask of the same parent, at the end of its
        // steps; a top-level task goes to the end of the global order.
        if let parent = source.parent {
            next.parent = parent
            next.parentID = parent.id
            store.inheritPlacement(next, from: parent)
            next.sortIndex = store.appendIndex(scope: .subtasks(parent))
        } else {
            next.sortIndex = store.appendIndex(scope: .tasksGlobal)
        }
        if existing == nil { store.context.insert(next) }

        // The successor of a parent gets fresh, open copies of its steps (title, notes,
        // priority, order); the steps' own dates, completion and history stay with the old one.
        // Their ids derive from the instance and the step, so a second spawn finds them too.
        let stepCopies: [KTask] = source.orderedChildren.map { s in
            let copyID = RecurrenceIdentity.stepCopyID(instanceID: nextID, stepID: s.id)
            let copy: KTask
            if let old = store.taskIncludingDeleted(copyID) {
                copy = old
                copy.deletedAt = nil
                copy.title = s.title
                copy.notes = s.notes
                copy.statusRaw = KStatus.todo.rawValue
                copy.completedAt = nil
            } else {
                copy = KTask(title: s.title, notes: s.notes, project: next.project)
                copy.id = copyID
                store.context.insert(copy)
            }
            copy.parent = next
            copy.parentID = next.id
            store.inheritPlacement(copy, from: next)
            copy.priorityRaw = s.priorityRaw
            copy.sortIndex = s.sortIndex
            copy.needsTriage = false
            return copy
        }

        store.saveContext()
        // One ordinary undo step for the rows we created. When `complete(_:)` called us we are
        // inside its `groupedUndo` block, so this collapses into the completion's single step;
        // called directly (as a test may), the spawn is undoable on its own. Either way this
        // file knows nothing about the undo stack's shape.
        store.groupedUndo("Repeat Task") {
            store.pushSoftDeleteUndoStep("Repeat Task", next)
            for c in stepCopies { store.pushSoftDeleteUndoStep("Repeat Task", c) }
        }
        return next
    }
}
