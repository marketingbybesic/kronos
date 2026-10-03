// Part of TaskStore: the two keyboard conversions behind Cmd-] and Cmd-[.
//
//   nestUnderTaskAbove          task    -> subtask of the task directly above it in the list
//   promoteSubtaskAfterParent   subtask -> standalone task right behind its parent
//
// Both are thin wrappers over the verified conversions in
// TaskStore+Hierarchy.swift: one undo step each, nothing pushed on refusal.

import Foundation

/// What happened to a Cmd-] request.
public enum NestKeyOutcome: Equatable {
    /// The task became a subtask of `parentID`.
    case nested(parentID: UUID)
    /// The task is first in the list (or not in it): there is nothing above to nest under.
    case noTaskAbove
    /// The conversion was refused; nothing changed.
    case refused(TaskNestError)
}

/// What the UI needs to know about one subtask without holding the model row.
public struct SubtaskRef: Equatable {
    public let id: UUID
    public let title: String
    /// The owning task, nil for an orphan row.
    public let parentID: UUID?
}

@MainActor
extension TaskStore {

    /// The subtask with this id, or nil when it is gone or is not a subtask.
    public func subtaskRef(_ id: UUID) -> SubtaskRef? {
        task(id).flatMap { t in t.parentID.map { SubtaskRef(id: t.id, title: t.title, parentID: $0) } }
    }

    /// Cmd-]: make `taskID` a subtask of the row directly above it in `rows`, the visible
    /// list order (ids only, so the caller's sort and filter decide "above"). A subtask above
    /// makes the task its sibling under the same parent.
    /// REGISTERS UNDO (one step) on success only.
    public func nestUnderTaskAbove(_ taskID: UUID, rows: [UUID]) -> NestKeyOutcome {
        guard let aboveID = KeyboardNesting.taskAbove(taskID, in: rows) else { return .noTaskAbove }
        // One level only: when the row above is itself a subtask, the task becomes its sibling
        // (nested under the same parent) instead of being refused.
        let parentID = task(aboveID)?.parentID ?? aboveID
        do {
            try makeTaskSubtaskOf(taskID, parentID: parentID)
            return .nested(parentID: parentID)
        } catch let e as TaskNestError {
            return .refused(e)
        } catch {
            return .refused(.taskNotFound)
        }
    }

    /// Cmd-[: promote a subtask to a standalone task placed directly after its former
    /// parent. Nil (nothing pushed) when the subtask is gone or has no parent.
    /// REGISTERS UNDO (one step).
    @discardableResult
    public func promoteSubtaskAfterParent(_ subtaskID: UUID) -> KTask? {
        promoteSubtaskToTask(subtaskID, afterParent: true)
    }
}

// MARK: - Planning keys

@MainActor
extension TaskStore {

    /// T: plan the selected tasks for today, as one undo step.
    public func planForToday(_ ids: [UUID], today: Int = Day.today()) {
        plan(ids, day: today)
    }

    /// H: plan the selected tasks for tomorrow (deadlines untouched), as one undo step.
    public func planForTomorrow(_ ids: [UUID], today: Int = Day.today()) {
        plan(ids, day: today + 1)
    }
}
