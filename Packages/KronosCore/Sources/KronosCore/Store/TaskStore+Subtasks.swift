// Part of TaskStore: the step ("subtask") API under its original names.
//
// A subtask is a child `KTask` (TaskStore+Hierarchy.swift). These methods keep the names the app,
// MCP and the tests have always called, as thin wrappers over the task APIs: a step id IS a task
// id, so toggling a step completes or reopens that task, its due day is `setDue`, its notes are
// the task's notes, and so on. Each wrapper inherits the undo behaviour of the task API it calls
// (one step, nothing pushed for a no-op). The step field editors use `mutateReversible`, whose
// redo re-arms the undo, so Cmd-Z / Cmd-Shift-Z alternate in the step editor.

import Foundation
import SwiftData

@MainActor
extension TaskStore {

    // MARK: - Create

    /// Append a step to `taskID`. REGISTERS UNDO. Nil when the task is gone or is a subtask.
    @discardableResult
    public func addSubtask(_ taskID: UUID, title: String) -> KTask? {
        addChild(to: taskID, title: title)
    }

    // MARK: - Done state

    /// Flip one step: an open step is completed (`complete`, which also spawns the next
    /// occurrence of a recurring step), a closed one reopened. REGISTERS UNDO (one step).
    public func toggleSubtask(_ id: UUID) {
        guard let t = task(id) else { return }
        if KStatus.closed.contains(t.status) {
            reopen(id)
        } else {
            complete(id)   // announces .kronosSubtaskDidComplete for a subtask
        }
    }

    // MARK: - Fields

    /// Retitle one step. REGISTERS UNDO; no-op when unchanged.
    public func renameSubtask(_ id: UUID, title: String) {
        guard let t = task(id), t.title != title else { return }
        mutateReversible("Rename Step", id) { $0.title = title }
    }

    /// Replace a step's notes (description and links). REGISTERS UNDO; no-op when unchanged.
    public func updateSubtaskNotes(_ id: UUID, notes: String) {
        guard let t = task(id), t.notes != notes else { return }
        mutateReversible("Update Subtask Notes", id) { $0.notes = notes }
    }

    /// Set or clear a step's due day. REGISTERS UNDO; no-op when unchanged.
    public func setSubtaskDueDay(_ id: UUID, _ day: Int?) {
        guard let t = task(id), t.dueDay != day else { return }
        mutateReversible("Set Step Due", id) { r in
            r.dueDay = day
            if r.originalDueDay == nil { r.originalDueDay = day }
        }
    }

    /// Set a step's priority. REGISTERS UNDO; no-op when unchanged.
    public func setSubtaskPriority(_ id: UUID, _ priority: KPriority) {
        guard let t = task(id), t.priority != priority else { return }
        mutateReversible("Set Step Priority", id) { $0.priority = priority }
    }

    // MARK: - Order, delete

    /// Move a step directly before `before` (a sibling), or to the end when nil.
    /// REGISTERS UNDO (one step).
    public func reorderSubtask(_ id: UUID, before targetID: UUID?) {
        reorderChild(id, before: targetID)
    }

    /// Remove a step (soft delete, like any task). REGISTERS UNDO (one step).
    public func deleteSubtask(_ id: UUID) {
        guard task(id) != nil else { return }
        softDelete(id)
    }

    // MARK: - Between levels

    /// Promote a subtask to a top-level task at the end of the manual order. The row keeps its
    /// id, every field, its project/area. Returns it, or nil when it is gone or not a subtask.
    /// REGISTERS UNDO (one step).
    @discardableResult
    public func promoteSubtaskToTask(_ subtaskID: UUID) -> KTask? {
        promoteSubtaskToTask(subtaskID, afterParent: false)
    }

    /// As `promoteSubtaskToTask(_:)`; `afterParent` places it directly behind its former parent.
    /// REGISTERS UNDO (one step).
    @discardableResult
    public func promoteSubtaskToTask(_ subtaskID: UUID, afterParent: Bool) -> KTask? {
        guard let t = task(subtaskID), t.isSubtask else { return nil }
        do { try setParent(subtaskID, to: nil, at: afterParent ? .afterFormerParent : .end) }
        catch { return nil }
        return task(subtaskID)
    }

    /// Move a subtask under another task, at the end of its steps. A no-op (nothing pushed)
    /// when the target is the current parent, a subtask, or either row is gone.
    /// REGISTERS UNDO (one step).
    public func reparentSubtask(_ subtaskID: UUID, under newParentID: UUID) {
        guard let t = task(subtaskID), t.isSubtask, t.parentID != newParentID else { return }
        try? setParent(subtaskID, to: newParentID, at: .end)
    }

    /// Make a task a subtask of `parentID` (Cmd-]). Its own subtasks follow it, in order, as
    /// siblings under the new parent. Throws `TaskNestError` (nothing changed, nothing pushed).
    /// REGISTERS UNDO (one step).
    public func makeTaskSubtaskOf(_ taskID: UUID, parentID: UUID) throws {
        try setParent(taskID, to: parentID, at: .end)
    }
}
