// Part of TaskStore, split out to keep every file under
// 500 lines (pure move: no renames, no behaviour change). The undoable mutation surface.
//
// Extensions in a separate file cannot see `private` members, so the undo
// plumbing these rely on (undoStack, redoStack, saveContext, mutateUndoable,
// scopeIndices, appendIndex, pushTopIndex) is internal rather than private.
// It is still not `public`: nothing outside KronosCore can reach it.

import Foundation
import SwiftData

@MainActor
extension TaskStore {
    // MARK: - Creation & mutation

    @discardableResult
    public func create(title: String, notes: String = "", project: KProject? = nil,
                       status: KStatus = .todo, priority: KPriority = .none,
                       dueDay: Int? = nil) -> KTask {
        let t = KTask(title: title, notes: notes, project: project)
        t.status = status
        t.priority = priority
        t.dueDay = dueDay
        t.originalDueDay = dueDay
        t.sortIndex = appendIndex(scope: .tasksGlobal)
        context.insert(t)
        saveContext()
        // Undo HIDES the row via soft delete rather than hard-deleting it: a
        // deleted-and-saved model cannot be re-inserted (see the note on
        // `deleteUndoable`), and KTask already has first-class soft delete.
        // The 30-day purge sweeps it if the user never redoes.
        pushSoftDeleteUndoStep("New Task", t)
        // Every interactive creation path (quick add, new task, Capture, MCP) lands here; imports
        // and recurrence spawns do not. The app listens to run auto-triage (fill-only).
        NotificationCenter.default.post(name: .kronosTaskDidCreate, object: nil, userInfo: ["taskID": t.id])
        return t
    }

    public func update(_ id: UUID, _ mutate: (KTask) -> Void) {
        mutateUndoable("Edit", id, mutate)
    }

    /// Mark done, and spawn the next occurrence when the task recurs.
    ///
    /// `wasOpen` is captured BEFORE the write: completing an already-done task
    /// (a double-click, an MCP retry) must not produce a second sibling. The
    /// completion and the spawn share one `groupedUndo` step, so Cmd-Z
    /// reopens the task AND removes the successor in one keystroke.
    /// REGISTERS UNDO (one step, even when a successor was spawned).
    public func complete(_ id: UUID) {
        let wasOpen = task(id)?.status != .done
        groupedUndo("Complete") {
            update(id) { t in
                t.status = .done
                t.completedAt = Date()
            }
            if wasOpen {
                RecurrenceSpawner.spawnNext(for: id, completedOn: Day.today(), in: self)
            }
        }
        if wasOpen && !isMachineWrite {
            NotificationCenter.default.post(name: .kronosTaskDidComplete, object: nil, userInfo: ["taskID": id])
        }
    }

    public func reopen(_ id: UUID) {
        update(id) { t in
            t.status = .todo
            t.completedAt = nil
        }
    }

    public func setStatus(_ id: UUID, _ s: KStatus) {
        update(id) { t in
            t.status = s
            if KStatus.closed.contains(s) { t.completedAt = Date() }
            else { t.completedAt = nil }
            // O4/O5: waiting/someday leave ORDO
            if s == .waiting || s == .someday { t.ordoIndex = nil }
        }
    }

    public func setPriority(_ id: UUID, _ p: KPriority) {
        update(id) { $0.priority = p }
    }

    public func setEffort(_ id: UUID, _ e: KEffort) {
        update(id) { $0.effort = e }
    }

    public func setDue(_ id: UUID, day: Int?) {
        update(id) { t in
            t.dueDay = day
            if t.originalDueDay == nil { t.originalDueDay = day }
        }
    }

    public func snooze(_ id: UUID) {
        update(id) { t in
            t.dueDay = (t.dueDay ?? Day.today()) + 1
            if t.originalDueDay == nil { t.originalDueDay = t.dueDay }
        }
    }

    public func move(_ id: UUID, toProject project: KProject?) {
        update(id) { t in
            t.project = project
            t.projectID = project?.id
            t.areaID = project?.area?.id
            t.isProjectArchived = project?.isArchived ?? false
        }
    }

    public func sendToOrdo(_ id: UUID, top: Bool = false) {
        update(id) { t in
            t.ordoIndex = top ? pushTopIndex(scope: .ordo) : appendIndex(scope: .ordo)
        }
    }

    public func removeFromOrdo(_ id: UUID) {
        update(id) { t in t.ordoIndex = nil }
    }

    public func softDelete(_ id: UUID) {
        update(id) { t in
            t.deletedAt = Date()
            t.ordoIndex = nil
        }
    }

    public func restore(_ id: UUID) {
        updateIncludingDeleted(id) { t in t.deletedAt = nil }
    }

    /// build-4: only this method writes ordoIndex ordering on drag.
    public func reorderOrdo(_ id: UUID, before targetID: UUID?) {
        let members = allTasks().filter { $0.ordoIndex != nil }
        let sorted = members.sorted(by: Ordering.ordo)
        guard let moving = sorted.first(where: { $0.id == id }) else { return }
        var before: KTask?
        if let tid = targetID { before = sorted.first { $0.id == tid } }
        let newIdx: Double
        if let b = before {
            if let i = sorted.firstIndex(where: { $0.id == b.id }), i > 0 {
                newIdx = (sorted[i - 1].ordoIndex! + b.ordoIndex!) / 2
            } else {
                newIdx = b.ordoIndex! - 1024
            }
        } else {
            newIdx = (sorted.last?.ordoIndex ?? -1024) + 1024
        }
        let oldIdx = moving.ordoIndex
        moving.ordoIndex = newIdx
        moving.updatedAt = Date()
        undoStack.append(("Reorder Ordo", { [weak self] in
            guard let self else { return }
            if let live = self.taskIncludingDeleted(moving.id) { live.ordoIndex = oldIdx }
            self.saveContext()
            self.redoStack.append(("Reorder Ordo", { [weak self] in
                guard let self else { return }
                if let live = self.taskIncludingDeleted(moving.id) { live.ordoIndex = newIdx }
                self.saveContext()
            }))
        }))
        redoStack.removeAll()
        saveContext()
    }

    /// O1/O2: every ORDO task with status in closed → ordoIndex = nil.
    public func clearDoneFromOrdo() {
        // Snapshot the affected tasks so the whole sweep is one undo step.
        let done = allTasks().filter { $0.ordoIndex != nil && KStatus.closed.contains($0.status) }
        guard !done.isEmpty else { return }
        let before = done.map { (id: $0.id, idx: $0.ordoIndex) }
        let after: [(id: UUID, idx: Double?)] = done.map { ($0.id, nil) }
        for t in done {
            t.ordoIndex = nil
            t.updatedAt = Date()
        }
        func apply(_ states: [(id: UUID, idx: Double?)]) {
            for s in states {
                if let live = taskIncludingDeleted(s.id) { live.ordoIndex = s.idx }
            }
        }
        undoStack.append(("Clear Done", { [weak self] in
            guard let self else { return }
            apply(before)
            self.redoStack.append(("Clear Done", { [weak self] in
                guard self != nil else { return }
                apply(after)
            }))
        }))
        redoStack.removeAll()
        saveContext()
    }

}
