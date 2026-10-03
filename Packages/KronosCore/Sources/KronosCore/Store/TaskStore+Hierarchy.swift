// Part of TaskStore: the task hierarchy. A subtask is a `KTask` with a parent (one level).
//
//   addChild     create a subtask under a task
//   setParent    the ONE move between levels: nest (task -> subtask), promote (subtask -> task),
//                reparent (subtask -> another task's subtask) and reorder among siblings
//   reorderChild move a subtask among its siblings
//
// Rules, enforced here and nowhere else:
//   - one level: a subtask never gets children; a task that has children and is nested
//     hands them to the new parent as siblings directly after it, in order (flatten);
//   - a task is never its own parent, and a subtask is never a target;
//   - a subtask carries its parent's project/area (the scalar mirrors included);
//   - ids never change: nesting and promoting move the same row.
// Every operation is ONE undo step that restores the exact prior parent, sortIndex and
// project/area of every row it touched; a no-op pushes nothing.

import Foundation
import SwiftData

/// Why `setParent` refused. Nothing is changed and no undo step is pushed when it throws.
public enum TaskNestError: Error, Equatable, LocalizedError {
    case taskNotFound
    case parentNotFound
    case sameTask
    /// One level only: the target is itself a subtask, so it cannot take children.
    case parentIsSubtask

    public var errorDescription: String? {
        switch self {
        case .taskNotFound: return "The task no longer exists."
        case .parentNotFound: return "The target task no longer exists."
        case .sameTask: return "A task cannot become a subtask of itself."
        case .parentIsSubtask: return "A subtask cannot have subtasks of its own."
        }
    }
}

/// Where a row lands when `setParent` moves it.
public enum KNestPlacement: Equatable, Sendable {
    /// After the destination's last row (the parent's last subtask, or the last top-level task).
    case end
    /// Directly before this row of the destination; a row that is not in the destination
    /// falls back to `.end`.
    case before(UUID)
    /// Directly behind the former parent in manual order. Meaningful when promoting a subtask
    /// (Cmd-[); anywhere else it means `.end`.
    case afterFormerParent
}

/// The hierarchy fields of one row, so undo/redo restore them exactly.
struct HierarchyState: Equatable {
    let id: UUID
    var parentID: UUID?, sortIndex: Double
    var projectID: UUID?, areaID: UUID?, isProjectArchived: Bool
    var ordoIndex: Double?
    var updatedAt: Date

    init(_ t: KTask) {
        id = t.id; parentID = t.parentID; sortIndex = t.sortIndex
        projectID = t.projectID; areaID = t.areaID; isProjectArchived = t.isProjectArchived
        ordoIndex = t.ordoIndex
        updatedAt = t.updatedAt
    }

    /// Same placement, ignoring the timestamp.
    func samePlacement(as o: HierarchyState) -> Bool {
        id == o.id && parentID == o.parentID && sortIndex == o.sortIndex
            && projectID == o.projectID && areaID == o.areaID && isProjectArchived == o.isProjectArchived
            && ordoIndex == o.ordoIndex
    }
}

@MainActor
extension TaskStore {

    // MARK: - Reads

    /// The live subtask with this id, nil for a missing row or a top-level task.
    func subtask(_ id: UUID) -> KTask? {
        task(id).flatMap { $0.isSubtask ? $0 : nil }
    }

    /// Live subtasks of `id` in manual order (empty for a missing task or a subtask).
    public func children(of id: UUID) -> [KTask] {
        taskIncludingDeleted(id)?.orderedChildren ?? []
    }

    // MARK: - Create

    /// Create a subtask at the end of `parentID`'s subtasks. It inherits the parent's
    /// project/area, starts open (`.todo`), is never auto-triaged, and gets the optional due
    /// day and priority. Nil (nothing pushed) when the parent is gone or is itself a subtask.
    /// REGISTERS UNDO (one step; undo hides the row, redo shows it again).
    @discardableResult
    public func addChild(to parentID: UUID, title: String, dueDay: Int? = nil,
                         priority: KPriority = .none) -> KTask? {
        guard let parent = task(parentID), !parent.isSubtask else { return nil }
        let c = KTask(title: title, notes: "", project: parent.project)
        inheritPlacement(c, from: parent)
        c.parent = parent
        c.parentID = parent.id
        c.status = .todo
        c.priority = priority
        c.dueDay = dueDay
        c.originalDueDay = dueDay
        c.needsTriage = false
        c.sortIndex = appendIndex(scope: .subtasks(parent))
        context.insert(c)
        parent.updatedAt = Date()
        saveContext()
        pushSoftDeleteUndoStep("Add Step", c)
        return c
    }

    // MARK: - Move between levels

    /// Set (`parentID` non-nil) or clear (nil) the parent of `id`, placing it per `placement`.
    ///
    /// - Nesting a task that has subtasks flattens: they become siblings directly after it
    ///   under the new parent, in order, keeping their ids (deleted ones move too, so the
    ///   hierarchy can never become two levels deep through a later restore).
    /// - A nested row takes the new parent's project/area; a promoted row keeps the
    ///   project/area it had (its former parent's).
    /// - Same parent: a reorder among siblings; a placement the row already has is a no-op.
    ///
    /// Throws `TaskNestError` without changing anything for a missing row, a missing target,
    /// the row itself as target, or a subtask as target.
    /// REGISTERS UNDO (one step) unless nothing changed.
    public func setParent(_ id: UUID, to parentID: UUID?, at placement: KNestPlacement = .end) throws {
        guard let moving = task(id) else { throw TaskNestError.taskNotFound }
        var newParent: KTask?
        if let pid = parentID {
            guard pid != id else { throw TaskNestError.sameTask }
            guard let p = task(pid) else { throw TaskNestError.parentNotFound }
            guard !p.isSubtask else { throw TaskNestError.parentIsSubtask }
            newParent = p
        }
        let formerParentID = moving.parentID

        // Rows that move: the row, plus (when nesting) every child it has.
        let carried: [KTask] = newParent == nil ? [] : (moving.children ?? []).sorted(by: Ordering.manual)
        let affected = [moving] + carried
        let before = affected.map(HierarchyState.init)
        let movingIDs = Set(affected.map(\.id))

        // Destination order without the rows that move.
        let destination: [KTask] = (newParent.map { ($0.children ?? []) } ?? allTasks())
            .filter { !movingIDs.contains($0.id) }
            .sorted(by: Ordering.manual)
        let plan = landingPlan(placement: placement, destination: destination,
                               formerParentID: formerParentID, nesting: newParent != nil,
                               current: formerParentID == parentID ? moving.sortIndex : nil)
        let index = plan.index
        // Destination rows respaced because the gap ran out (at most the two direct neighbours).
        let neighbours = destination.filter { plan.neighbours[$0.id] != nil }
        let beforeAll = before + neighbours.map(HierarchyState.init)
        let now = Date()
        for n in neighbours {
            n.sortIndex = plan.neighbours[n.id] ?? n.sortIndex
            n.updatedAt = now
        }
        // The carried children fill the gap between the row and the next destination row.
        let next = destination.map(\.sortIndex).filter { $0 > index }.min()
        let step = next.map { ($0 - index) / Double(carried.count + 1) } ?? 1024

        moving.parent = newParent
        moving.parentID = newParent?.id
        moving.sortIndex = index
        moving.updatedAt = now
        if let p = newParent { inheritPlacement(moving, from: p) }
        // The ORDO queue lists top-level tasks only: a row that becomes a subtask leaves it.
        if newParent != nil { moving.ordoIndex = nil }
        for (i, c) in carried.enumerated() {
            c.parent = newParent
            c.parentID = newParent?.id
            c.sortIndex = index + step * Double(i + 1)
            c.updatedAt = now
            if let p = newParent { inheritPlacement(c, from: p) }
            if newParent != nil { c.ordoIndex = nil }
        }
        if let p = newParent { p.updatedAt = now }

        let after = (affected + neighbours).map(HierarchyState.init)
        guard zip(beforeAll, after).contains(where: { !$0.samePlacement(as: $1) }) else {
            // Nothing moved (e.g. `.before` the row that already follows): restore the
            // timestamps and push nothing.
            applyHierarchy(beforeAll)
            saveContext()
            return
        }
        saveContext()
        let name = newParent == nil ? (formerParentID == nil ? "Reorder" : "Convert to Task")
                                    : (formerParentID == newParent?.id ? "Reorder Steps" : "Make Subtask")
        pushReversible(name, touching: Set((affected + neighbours).map(\.id)), clearRedo: true, undo: { [self] in applyHierarchy(beforeAll) },
                       redo: { [self] in applyHierarchy(after) })
    }

    /// Move subtask `id` directly before sibling `before`, or to the end when nil.
    /// A no-op for a top-level task or when nothing changes.
    /// REGISTERS UNDO (one step).
    public func reorderChild(_ id: UUID, before target: UUID?) {
        guard let t = task(id), let pid = t.parentID else { return }
        try? setParent(id, to: pid, at: target.map { .before($0) } ?? .end)
    }

    // MARK: - Helpers

    /// `mutateUndoable` for ONE standalone edit whose redo re-arms its undo, so Cmd-Z and
    /// Cmd-Shift-Z alternate any number of times (the step editors rely on that). Not for use
    /// inside `groupedUndo`, whose redo replays children without re-arming. No-op when the
    /// mutation changes nothing.
    func mutateReversible(_ name: String, _ id: UUID, _ mutate: (KTask) -> Void) {
        guard let t = taskIncludingDeleted(id) else { return }
        let before = TaskSnapshot(t)
        mutate(t)
        applyAutomaticStatusRule(to: t, dueDayBefore: before.dueDay)
        let after = TaskSnapshot(t)
        let changed = after.changedFields(from: before)
        // Nothing the snapshot covers changed: save whatever else was written, push no step,
        // keep the redo stack and leave `updatedAt` alone.
        guard !changed.isEmpty else { saveContext(); return }
        t.updatedAt = Date()
        // Field-level, like `mutateUndoable`: undo/redo rewrite only the fields this edit
        // changed, so a machine (MCP) write to another field in between survives.
        let resolve: (UUID) -> KTask? = { [unowned self] in self.taskIncludingDeleted($0) }
        pushReversible(name, touching: [id], clearRedo: true, undo: { [self] in
            if let live = taskIncludingDeleted(id) {
                before.apply(to: live, only: changed, resolveTask: resolve)
                live.updatedAt = Date()
            }
        }, redo: { [self] in
            if let live = taskIncludingDeleted(id) {
                after.apply(to: live, only: changed, resolveTask: resolve)
                live.updatedAt = Date()
            }
        })
        saveContext()
    }

    /// Push one undo step whose redo re-arms the undo again, so Cmd-Z / Cmd-Shift-Z can
    /// alternate any number of times. `clearRedo` is true for a fresh user action and false
    /// when the step is being re-armed by a redo.
    func pushReversible(_ name: String, touching touched: Set<UUID>, clearRedo: Bool,
                        undo: @escaping () -> Void, redo: @escaping () -> Void) {
        undoStack.append(name, touching: touched) { [weak self] in
            guard let self else { return }
            undo()
            self.saveContext()
            self.redoStack.append(name, touching: touched) { [weak self] in
                guard let self else { return }
                redo()
                self.saveContext()
                self.pushReversible(name, touching: touched, clearRedo: false, undo: undo, redo: redo)
            }
        }
        if clearRedo { redoStack.removeAll() }
    }

    /// Copy the parent's project and the scalar mirrors `#Predicate` reads.
    func inheritPlacement(_ child: KTask, from parent: KTask) {
        if child.project !== parent.project { child.project = parent.project }
        child.projectID = parent.projectID
        child.areaID = parent.areaID
        child.isProjectArchived = parent.isProjectArchived
    }

    func applyHierarchy(_ states: [HierarchyState]) {
        for s in states {
            guard let t = taskIncludingDeleted(s.id) else { continue }
            let p = s.parentID.flatMap { taskIncludingDeleted($0) }
            if t.parent !== p { t.parent = p }
            t.parentID = s.parentID
            t.sortIndex = s.sortIndex
            if t.projectID != s.projectID {
                t.project = s.projectID.flatMap { pid in allProjects(includeArchived: true).first { $0.id == pid } }
            }
            t.projectID = s.projectID
            t.areaID = s.areaID
            t.isProjectArchived = s.isProjectArchived
            t.ordoIndex = s.ordoIndex
            t.updatedAt = s.updatedAt
        }
    }

    /// `current` is the row's own index when it stays under the same parent: a placement it
    /// already satisfies keeps that index, so the move is recognised as a no-op. A gap that ran
    /// out respaces only the two direct neighbours (`NeighbourPlacement`).
    private func landingPlan(placement: KNestPlacement, destination: [KTask],
                             formerParentID: UUID?, nesting: Bool, current: Double?) -> NeighbourPlacement.Plan {
        let rows = destination.map { (id: $0.id, idx: $0.sortIndex) }
        let maxIdx = rows.map(\.idx).max()
        let end = NeighbourPlacement.Plan(index: (maxIdx ?? -1024) + 1024)
        switch placement {
        case .end:
            if let current, current > (maxIdx ?? -.infinity) { return .init(index: current) }
            return end
        case .before(let target):
            guard let i = rows.firstIndex(where: { $0.id == target }) else {
                if let current, current > (maxIdx ?? -.infinity) { return .init(index: current) }
                return end
            }
            let above = i > 0 ? rows[i - 1].idx : -Double.infinity
            if let current, current > above, current < rows[i].idx { return .init(index: current) }
            return NeighbourPlacement.plan(rows: rows, slot: i)
        case .afterFormerParent:
            guard !nesting, let fp = formerParentID,
                  let anchor = rows.firstIndex(where: { $0.id == fp }) else { return end }
            return NeighbourPlacement.plan(rows: rows, slot: anchor + 1)
        }
    }
}
