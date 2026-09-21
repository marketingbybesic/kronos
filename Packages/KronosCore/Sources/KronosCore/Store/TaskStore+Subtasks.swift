// Part of TaskStore. `addSubtask` and `toggleSubtask` are a
// pure move out of TaskStore+Mutations.swift (no renames, no behaviour
// change) so both files stay well under 500 lines; `reorderSubtask`,
// `renameSubtask` and `deleteSubtask` are later additions the inspector
// needed and had to disable for want of an API.
//
// Extensions in a separate file cannot see `private` members, so the undo
// plumbing these rely on (undoStack, redoStack, saveContext, appendIndex) is
// internal rather than private. It is still not `public`.

import Foundation
import SwiftData

@MainActor
extension TaskStore {

    /// Every subtask row in the store, ordered by the full tie-break chain.
    /// Subtasks are fetched globally and filtered by id rather than through
    /// `task.subtasks`, because a to-many relationship carries no order
    /// (data-14) and the id lookup is what every mutation below needs.
    func subtask(_ id: UUID) -> KSubtask? {
        let d = FetchDescriptor<KSubtask>()
        return ((try? context.fetch(d)) ?? []).first { $0.id == id }
    }

    // MARK: - Create / toggle (moved verbatim from +Mutations)

    @discardableResult
    public func addSubtask(_ taskID: UUID, title: String) -> KSubtask? {
        guard let t = task(taskID) else { return nil }
        let s = KSubtask(title: title)
        s.sortIndex = appendIndex(scope: .subtasks(t))
        s.task = t
        context.insert(s)
        t.updatedAt = Date()
        // Undo DETACHES the step rather than hard-deleting it, for the same
        // reason `deleteSubtask` does: a deleted-and-saved model cannot be
        // re-inserted, and a detached step is already invisible to every
        // reader, all of which go through `orderedSubtasks`.
        undoStack.append(("Add Step", { [weak self] in
            guard let self else { return }
            s.task = nil
            self.saveContext()
            self.redoStack.append(("Add Step", { [weak self] in
                guard let self else { return }
                s.task = self.taskIncludingDeleted(taskID)
                self.saveContext()
            }))
        }))
        redoStack.removeAll()
        saveContext()
        return s
    }

    public func toggleSubtask(_ id: UUID) {
        guard let s = subtask(id) else { return }
        let wasDone = s.isDone
        s.isDone.toggle()
        s.updatedAt = Date()
        if !wasDone && !isMachineWrite {
            NotificationCenter.default.post(name: .kronosSubtaskDidComplete, object: nil, userInfo: ["subtaskID": id])
        }
        undoStack.append(("Check Step", { [weak self] in
            guard let self else { return }
            s.isDone = wasDone
            self.saveContext()
            self.redoStack.append(("Check Step", { [weak self] in
                guard let self else { return }
                s.isDone = !wasDone
                self.saveContext()
            }))
        }))
        redoStack.removeAll()
        saveContext()
    }

    // MARK: - rev 4: rename / reorder / delete

    /// REGISTERS UNDO (one step).
    public func renameSubtask(_ id: UUID, title: String) {
        guard let s = subtask(id) else { return }
        let before = s.title
        guard before != title else { return }
        s.title = title
        s.updatedAt = Date()
        undoStack.append(("Rename Step", { [weak self] in
            guard let self else { return }
            s.title = before
            self.saveContext()
            self.redoStack.append(("Rename Step", { [weak self] in
                guard let self else { return }
                s.title = title
                self.saveContext()
            }))
        }))
        redoStack.removeAll()
        saveContext()
    }

    /// Move `id` to sit directly before `before`, or to the end when `before`
    /// is nil — the same between-index arithmetic `reorderOrdo` uses, within
    /// one task's step list. REGISTERS UNDO (one step).
    public func reorderSubtask(_ id: UUID, before targetID: UUID?) {
        guard let moving = subtask(id), let owner = moving.task else { return }
        let rows = owner.orderedSubtasks.map { (id: $0.id, idx: $0.sortIndex) }
        let newIdx = betweenIndex(for: id, before: targetID, in: rows)
        let oldIdx = moving.sortIndex
        guard oldIdx != newIdx else { return }
        moving.sortIndex = newIdx
        moving.updatedAt = Date()
        undoStack.append(("Reorder Steps", { [weak self] in
            guard let self else { return }
            moving.sortIndex = oldIdx
            self.saveContext()
            self.redoStack.append(("Reorder Steps", { [weak self] in
                guard let self else { return }
                moving.sortIndex = newIdx
                self.saveContext()
            }))
        }))
        redoStack.removeAll()
        saveContext()
    }

    /// Remove a step. REGISTERS UNDO (one step).
    ///
    /// Undo re-attaches the row rather than re-inserting a deleted model:
    /// SwiftData does not guarantee a deleted-and-saved `PersistentModel` can
    /// be reinserted (the same trap `RecurrenceSpawner` documents). The step
    /// is detached from its task and its index remembered, so undo puts it
    /// back exactly where it was.
    public func deleteSubtask(_ id: UUID) {
        guard let s = subtask(id), let owner = s.task else { return }
        let ownerID = owner.id
        let idx = s.sortIndex
        s.task = nil
        owner.updatedAt = Date()
        undoStack.append(("Delete Step", { [weak self] in
            guard let self else { return }
            s.task = self.taskIncludingDeleted(ownerID)
            s.sortIndex = idx
            self.saveContext()
            self.redoStack.append(("Delete Step", { [weak self] in
                guard let self else { return }
                s.task = nil
                self.saveContext()
            }))
        }))
        redoStack.removeAll()
        saveContext()
    }
}
