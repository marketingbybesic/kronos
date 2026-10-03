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
        // Avoidance language in the words the person typed flags the task from the start.
        if DreadRules.shouldFlagOnCreate(title: title, notes: notes) { t.dread = true }
        context.insert(t)
        saveContext()
        // Undo HIDES the row via soft delete rather than hard-deleting it: a
        // deleted-and-saved model cannot be re-inserted (see the note on
        // `deleteUndoable`), and KTask already has first-class soft delete.
        // The 30-day purge sweeps it if the user never redoes.
        pushSoftDeleteUndoStep("New Task", t)
        // Every interactive creation path (quick add, new task, Capture, MCP) lands here; imports
        // and recurrence spawns do not. The app listens to run auto-triage (fill-only).
        // `origin` says who made it: a machine write (MCP, import, agents) goes through
        // `withoutUndo`, anything else is the user's own action.
        NotificationCenter.default.post(name: .kronosTaskDidCreate, object: nil, userInfo: [
            "taskID": t.id,
            Self.createOriginKey: isMachineWrite ? Self.createOriginMachine : Self.createOriginUser,
        ])
        return t
    }

    /// `userInfo` key of `.kronosTaskDidCreate` carrying the origin of the new task.
    public static let createOriginKey = "origin"
    public static let createOriginUser = "user"
    public static let createOriginMachine = "machine"

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
            // A subtask plays the step cue, a task the task cue — never both.
            if taskIncludingDeleted(id)?.isSubtask == true {
                NotificationCenter.default.post(name: .kronosSubtaskDidComplete, object: nil, userInfo: ["subtaskID": id])
            } else {
                NotificationCenter.default.post(name: .kronosTaskDidComplete, object: nil, userInfo: ["taskID": id])
            }
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

    /// Plan the task for tomorrow. The deadline is never touched: the planned day alone takes the
    /// task out of Today until tomorrow, so an overdue task stays honestly overdue. REGISTERS UNDO.
    public func snooze(_ id: UUID) {
        snooze(id, today: Day.today())
    }

    /// A subtask moved to a project other than its parent's becomes a standalone task (behind
    /// its former parent); a task's subtasks follow it. One undo step either way.
    public func move(_ id: UUID, toProject project: KProject?) {
        guard let moving = taskIncludingDeleted(id) else { return }
        groupedUndo("Move") {
            if moving.isSubtask, moving.parent?.projectID != project?.id {
                try? setParent(id, to: nil, at: .afterFormerParent)
            }
            let ids = [id] + (moving.children ?? []).map(\.id)
            for rowID in ids {
                updateIncludingDeleted(rowID) { t in
                    t.project = project
                    t.projectID = project?.id
                    t.areaID = project?.area?.id
                    t.isProjectArchived = project?.isArchived ?? false
                }
            }
        }
    }

    /// A subtask is never a member of the ORDO queue (the queue lists top-level tasks only), so
    /// sending one is a no-op and pushes no undo step.
    public func sendToOrdo(_ id: UUID, top: Bool = false) {
        guard task(id)?.isSubtask != true else { return }
        update(id) { t in
            t.ordoIndex = top ? pushTopIndex(scope: .ordo) : appendIndex(scope: .ordo)
        }
    }

    public func removeFromOrdo(_ id: UUID) {
        update(id) { t in t.ordoIndex = nil }
    }

    /// Deleting a task deletes its live subtasks with the same stamp, in ONE undo step, so
    /// undo (and `restore`) bring them back together.
    public func softDelete(_ id: UUID) {
        guard let t = task(id) else { return }
        let stamp = Date()
        let kids = t.orderedChildren.map(\.id)
        groupedUndo("Delete") {
            for rowID in [id] + kids {
                update(rowID) { r in
                    r.deletedAt = stamp
                    r.ordoIndex = nil
                }
            }
        }
    }

    /// Restoring a task restores the subtasks deleted together with it; restoring a subtask
    /// whose parent is deleted restores that parent too (a child is never visible alone).
    public func restore(_ id: UUID) {
        guard let t = taskIncludingDeleted(id) else { return }
        let stamp = t.deletedAt
        let kids = stamp == nil ? [] : (t.children ?? []).filter { $0.deletedAt == stamp }.map(\.id)
        let parent = t.parent?.deletedAt != nil ? t.parentID : nil
        groupedUndo("Restore") {
            for rowID in [id] + kids + (parent.map { [$0] } ?? []) {
                updateIncludingDeleted(rowID) { r in r.deletedAt = nil }
            }
        }
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
        undoStack.append("Reorder Up next", touching: [moving.id]) { [weak self] in
            guard let self else { return }
            if let live = self.taskIncludingDeleted(moving.id) { live.ordoIndex = oldIdx }
            self.saveContext()
            self.redoStack.append("Reorder Up next", touching: [moving.id]) { [weak self] in
                guard let self else { return }
                if let live = self.taskIncludingDeleted(moving.id) { live.ordoIndex = newIdx }
                self.saveContext()
            }
        }
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
        let touched = Set(done.map(\.id))
        undoStack.append("Clear Done", touching: touched) { [weak self] in
            guard let self else { return }
            apply(before)
            self.redoStack.append("Clear Done", touching: touched) { [weak self] in
                guard self != nil else { return }
                apply(after)
            }
        }
        redoStack.removeAll()
        saveContext()
    }

}

// MARK: - Task snapshot (field-level undo)

@MainActor
extension TaskStore {
    /// One undoable unit of a task. Related columns that always move together form one field
    /// (a project change also moves its `projectID`/`areaID`/`isProjectArchived` mirrors).
    enum TaskField: CaseIterable, Hashable {
        case title, notes, firstMove, status, priority, depth, effort, dread, energyKind, estimate
        case dueDay, originalDueDay, completedAt, sortIndex, ordoIndex, deletedAt, needsTriage
        case project, labels, parent, recurrence, waitsOn, calendarEvent, origin, triage
        /// Schema V2, user-editable: `plannedDay` with its `carryCount` (a replan resets the
        /// count in the same write), the review decision, and who the task is assigned to.
        case planned, review, assignee
        // Schema V2 columns deliberately NOT undoable (machine/system written; an undo must
        // never rewind them): triageFilledFieldsRaw and lockedFieldsRaw (TaskStore+Triage,
        // their own APIs, no undo step by design), contextJSON and resultJSON (agent
        // payloads), triageLeaseOwner and triageLeaseUntil (lease bookkeeping), attachments
        // (relationship, unused until attachments ship), updatedAt.
    }

    /// A copy of every undoable field of one task. Relationships (project, labels, parent) are
    /// held by id and looked up again when applied: a rebuilt row (an undone delete re-inserts a
    /// fresh instance with the same id) is found, a stale object reference would not be.
    struct TaskSnapshot {
        var title: String, notes: String, firstMove: String?
        var statusRaw: Int, priorityRaw: Int, depthRaw: Int, effortRaw: Int, dread: Bool
        var energyKindRaw: Int?, estimateMinutes: Int?
        var dueDay: Int?, originalDueDay: Int?, completedAt: Date?
        var sortIndex: Double, ordoIndex: Double?
        var deletedAt: Date?, needsTriage: Bool
        /// The scalar mirrors `#Predicate` reads travel with the project: restoring the
        /// relationship alone left a row claiming, say, `isProjectArchived == true` after its
        /// project's archiving had been undone, so filters kept hiding it.
        var projectID: UUID?, areaID: UUID?, isProjectArchived: Bool
        var recurrenceRule: String?, seriesID: UUID?
        var waitsOnIDs: String
        var labelIDs: Set<UUID>
        var parentID: UUID?
        /// Fallback for a caller that cannot resolve ids (see `apply`); the id is what counts.
        private var parentRef: KTask?
        var calendarEventID: String?
        var externalID: String?, source: String?
        var triagedAt: Date?, triageModel: String?, triageRationale: String?
        var triageFeedback: String?, triageReviewedAt: Date?
        var plannedDay: Int?, carryCount: Int
        var reviewRaw: Int
        var assigneeRaw: Int, agentID: UUID?

        init(_ t: KTask) {
            title = t.title; notes = t.notes; firstMove = t.firstMove
            statusRaw = t.statusRaw; priorityRaw = t.priorityRaw
            depthRaw = t.depthRaw; effortRaw = t.effortRaw; dread = t.dread
            energyKindRaw = t.energyKindRaw; estimateMinutes = t.estimateMinutes
            dueDay = t.dueDay; originalDueDay = t.originalDueDay
            completedAt = t.completedAt
            sortIndex = t.sortIndex; ordoIndex = t.ordoIndex
            deletedAt = t.deletedAt; needsTriage = t.needsTriage
            projectID = t.projectID; areaID = t.areaID
            isProjectArchived = t.isProjectArchived
            recurrenceRule = t.recurrenceRule; seriesID = t.seriesID
            waitsOnIDs = t.waitsOnIDs
            labelIDs = Set((t.labels ?? []).map(\.id))
            parentID = t.parentID ?? t.parent?.id
            parentRef = t.parent
            calendarEventID = t.calendarEventID
            externalID = t.externalID; source = t.source
            triagedAt = t.triagedAt; triageModel = t.triageModel
            triageRationale = t.triageRationale
            triageFeedback = t.triageFeedback; triageReviewedAt = t.triageReviewedAt
            plannedDay = t.plannedDay; carryCount = t.carryCount
            reviewRaw = t.reviewRaw
            assigneeRaw = t.assigneeRaw; agentID = t.agentID
        }

        /// The fields whose value differs from `other`.
        func changedFields(from other: TaskSnapshot) -> Set<TaskField> {
            var out = Set<TaskField>()
            func note(_ f: TaskField, _ differs: Bool) { if differs { out.insert(f) } }
            note(.title, title != other.title)
            note(.notes, notes != other.notes)
            note(.firstMove, firstMove != other.firstMove)
            note(.status, statusRaw != other.statusRaw)
            note(.priority, priorityRaw != other.priorityRaw)
            note(.depth, depthRaw != other.depthRaw)
            note(.effort, effortRaw != other.effortRaw)
            note(.dread, dread != other.dread)
            note(.energyKind, energyKindRaw != other.energyKindRaw)
            note(.estimate, estimateMinutes != other.estimateMinutes)
            note(.dueDay, dueDay != other.dueDay)
            note(.originalDueDay, originalDueDay != other.originalDueDay)
            note(.completedAt, completedAt != other.completedAt)
            note(.sortIndex, sortIndex != other.sortIndex)
            note(.ordoIndex, ordoIndex != other.ordoIndex)
            note(.deletedAt, deletedAt != other.deletedAt)
            note(.needsTriage, needsTriage != other.needsTriage)
            note(.project, projectID != other.projectID || areaID != other.areaID
                           || isProjectArchived != other.isProjectArchived)
            note(.labels, labelIDs != other.labelIDs)
            note(.parent, parentID != other.parentID)
            note(.recurrence, recurrenceRule != other.recurrenceRule || seriesID != other.seriesID)
            note(.waitsOn, waitsOnIDs != other.waitsOnIDs)
            note(.calendarEvent, calendarEventID != other.calendarEventID)
            note(.origin, externalID != other.externalID || source != other.source)
            note(.triage, triagedAt != other.triagedAt || triageModel != other.triageModel
                          || triageRationale != other.triageRationale
                          || triageFeedback != other.triageFeedback
                          || triageReviewedAt != other.triageReviewedAt)
            note(.planned, plannedDay != other.plannedDay || carryCount != other.carryCount)
            note(.review, reviewRaw != other.reviewRaw)
            note(.assignee, assigneeRaw != other.assigneeRaw || agentID != other.agentID)
            return out
        }

        /// Write the given fields (all of them when `only` is nil) back onto `t`.
        /// `resolveTask` finds a task by id; without it a parent falls back to the object the
        /// snapshot captured (fine for a caller that rewinds immediately).
        func apply(to t: KTask, only: Set<TaskField>? = nil, resolveTask: ((UUID) -> KTask?)? = nil) {
            for f in TaskField.allCases where only?.contains(f) ?? true { write(f, to: t, resolveTask) }
        }

        private func write(_ f: TaskField, to t: KTask, _ resolveTask: ((UUID) -> KTask?)?) {
            switch f {
            case .title: t.title = title
            case .notes: t.notes = notes
            case .firstMove: t.firstMove = firstMove
            case .status: t.statusRaw = statusRaw
            case .priority: t.priorityRaw = priorityRaw
            case .depth: t.depthRaw = depthRaw
            case .effort: t.effortRaw = effortRaw
            case .dread: t.dread = dread
            case .energyKind: t.energyKindRaw = energyKindRaw
            case .estimate: t.estimateMinutes = estimateMinutes
            case .dueDay: t.dueDay = dueDay
            case .originalDueDay: t.originalDueDay = originalDueDay
            case .completedAt: t.completedAt = completedAt
            case .sortIndex: t.sortIndex = sortIndex
            case .ordoIndex: t.ordoIndex = ordoIndex
            case .deletedAt: t.deletedAt = deletedAt
            case .needsTriage: t.needsTriage = needsTriage
            case .project:
                if let projectID {
                    // A project that no longer exists cannot be restored: leave the row alone.
                    guard let p = Self.fetchProject(projectID, in: t.modelContext) else { return }
                    if t.project?.id != projectID { t.project = p }
                } else if t.project != nil {
                    t.project = nil
                }
                t.projectID = projectID; t.areaID = areaID
                t.isProjectArchived = isProjectArchived
            case .labels:
                let live = Self.fetchLabels(labelIDs, in: t.modelContext)
                if Set((t.labels ?? []).map(\.id)) != Set(live.map(\.id)) { t.labels = live }
            case .parent:
                if let parentID {
                    if t.parent?.id != parentID {
                        // By id first (a rebuilt row is found); the captured object only when the
                        // caller gave no resolver and it is still the same row.
                        let p = resolveTask?(parentID) ?? (parentRef?.id == parentID ? parentRef : nil)
                        guard let p else { return }
                        t.parent = p
                    }
                } else if t.parent != nil {
                    t.parent = nil
                }
                t.parentID = parentID
            case .recurrence: t.recurrenceRule = recurrenceRule; t.seriesID = seriesID
            case .waitsOn: t.waitsOnIDs = waitsOnIDs
            case .calendarEvent: t.calendarEventID = calendarEventID
            case .origin: t.externalID = externalID; t.source = source
            case .triage:
                t.triagedAt = triagedAt; t.triageModel = triageModel
                t.triageRationale = triageRationale
                t.triageFeedback = triageFeedback; t.triageReviewedAt = triageReviewedAt
            case .planned: t.plannedDay = plannedDay; t.carryCount = carryCount
            case .review: t.reviewRaw = reviewRaw
            case .assignee: t.assigneeRaw = assigneeRaw; t.agentID = agentID
            }
        }

        private static func fetchProject(_ id: UUID, in ctx: ModelContext?) -> KProject? {
            guard let ctx else { return nil }
            var d = FetchDescriptor<KProject>(predicate: #Predicate { $0.id == id })
            d.fetchLimit = 1
            return (try? ctx.fetch(d))?.first
        }


        private static func fetchLabels(_ ids: Set<UUID>, in ctx: ModelContext?) -> [KLabel] {
            guard let ctx else { return [] }
            return ((try? ctx.fetch(FetchDescriptor<KLabel>())) ?? []).filter { ids.contains($0.id) }
        }
    }
}
