// Part of TaskStore. The per-field task setters the
// inspector needed.
//
// Every one of these is a thin, named wrapper over the existing undoable
// `update(_:_:)`, which already snapshots the whole row in both directions.
// They exist because a UI leaf calling `store.update(id) { $0.depth = .deep }`
// pushes an undo step named "Edit" and buries the intent; a named method
// documents which field it owns and keeps the mutation surface greppable.
// No new undo machinery: `update` is the single source of truth.

import Foundation

@MainActor
extension TaskStore {

    /// Attention demand (adhd-4: never emotional weight). REGISTERS UNDO.
    public func setDepth(_ id: UUID, _ d: KDepth) {
        update(id) { $0.depth = d }
    }

    /// Predicted duration in minutes; nil clears it. REGISTERS UNDO.
    public func setEstimate(_ id: UUID, minutes: Int?) {
        update(id) { $0.estimateMinutes = minutes }
    }

    /// The dread flag that switches the first-move generator to its
    /// ≤2-minute opener. REGISTERS UNDO. Switching it OFF by hand also locks it against triage (a later
    /// triage must not set it again); switching it ON lifts that lock. The lock is bookkeeping with no
    /// undo step of its own (`lockedFieldsRaw` is never rewound by undo), so an undo restores the flag only.
    public func setDread(_ id: UUID, _ dread: Bool) {
        update(id) { $0.dread = dread }
        if dread { unlockDread(on: id) } else { lockDread(on: id) }
    }

    /// Park the task in `.waiting`, or release it back to whatever status the
    /// automatic rule (`TaskStore.applyAutomaticStatusRule`) says its due day
    /// implies — `.todo` when it has one, `.someday` when it does not.
    /// The inspector's toggle used
    /// to be a Someday switch; it is now a Waiting switch, since Someday is
    /// never a manual pick any more.
    ///
    /// Routed through `setStatus` so O5 still applies (a waiting task leaves
    /// ORDO) and so the choke-point rule in `mutateUndoable` runs; turning
    /// waiting OFF sets a status that already equals what the rule would
    /// compute, so the rule's own idempotence guard leaves it exactly there.
    /// REGISTERS UNDO.
    public func setWaiting(_ id: UUID, _ waiting: Bool) {
        setWaiting(id, waiting, today: Day.today())
    }

    /// Days a waiting task stays out of Today before it comes back.
    public static let waitingResurfaceDays = 3

    /// `setWaiting` with the day injected. Parking a task also plans it `waitingResurfaceDays`
    /// from `today`, so it returns to Today by itself; releasing it drops a planned day that is
    /// still in the future (that deferral belonged to the waiting). One undo step.
    public func setWaiting(_ id: UUID, _ waiting: Bool, today: Int) {
        guard let t = task(id) else { return }
        let target: KStatus = waiting ? .waiting : (t.dueDay != nil ? .todo : .someday)
        guard t.status != target else { return }
        groupedUndo("Waiting") {
            setStatus(id, target)
            if waiting {
                writePlanning("Waiting", [id]) { $0.plannedDay = today + Self.waitingResurfaceDays }
            } else if let planned = t.plannedDay, planned > today {
                writePlanning("Waiting", [id]) { $0.plannedDay = nil }
            }
        }
    }

    /// The concrete next physical action. An empty or whitespace-only string
    /// clears it, so the inspector's text field deleting its contents means
    /// "no first move" rather than storing "". REGISTERS UNDO.
    public func setFirstMove(_ id: UUID, _ move: String?) {
        let trimmed = move?.trimmingCharacters(in: .whitespacesAndNewlines)
        update(id) { $0.firstMove = (trimmed?.isEmpty ?? true) ? nil : trimmed }
    }

    /// Set or clear the recurrence rule, as its wire string (`RecurrenceRule`
    /// round-trips through this form). An unparseable string is REJECTED
    /// rather than stored: a rule the engine cannot read would make the task
    /// silently non-recurring at completion time, which looks like data loss.
    /// Passing nil always clears. REGISTERS UNDO (none when rejected).
    public func setRecurrence(_ id: UUID, _ wire: String?) {
        if let wire, RecurrenceRule.parse(wire) == nil { return }
        update(id) { $0.recurrenceRule = wire }
    }

    /// Attach a label. Idempotent — attaching a label the task already
    /// carries is a no-op and pushes no undo step. REGISTERS UNDO.
    public func addLabel(_ label: KLabel, to id: UUID) {
        guard let t = task(id), !(t.labels ?? []).contains(where: { $0.id == label.id }) else { return }
        update(id) { $0.labels = ($0.labels ?? []) + [label] }
    }

    /// Detach a label. A label the task does not carry is a no-op.
    /// The `KLabel` row itself is left alone: labels are shared, and deleting
    /// one because its last task dropped it would remove it from the
    /// vocabulary the user built. REGISTERS UNDO.
    public func removeLabel(_ label: KLabel, from id: UUID) {
        guard let t = task(id), (t.labels ?? []).contains(where: { $0.id == label.id }) else { return }
        update(id) { $0.labels = ($0.labels ?? []).filter { $0.id != label.id } }
    }
}

// MARK: - Planning (plannedDay, carryCount)

/// The planning fields of one task, the only ones the planning writers touch.
struct PlanState: Equatable {
    var plannedDay: Int?
    var carryCount: Int

    init(_ t: KTask) { plannedDay = t.plannedDay; carryCount = t.carryCount }

    func apply(to t: KTask) { t.plannedDay = plannedDay; t.carryCount = carryCount }
}

@MainActor
extension TaskStore {

    /// Plan the task for `day` (nil clears the plan). Planning is the person's fresh commitment,
    /// so a day also resets the carry count. The deadline is never written. A write that changes
    /// nothing pushes no undo step. REGISTERS UNDO.
    public func plan(_ id: UUID, day: Int?) {
        writePlanning("Plan", [id]) { t in
            t.plannedDay = day
            if day != nil { t.carryCount = 0 }
        }
    }

    /// Plan the task for tomorrow, counted from `today`. REGISTERS UNDO.
    public func snooze(_ id: UUID, today: Int) {
        plan(id, day: today + 1)
    }

    /// Plan several tasks for one day (or clear their plans) as ONE undo step.
    public func plan(_ ids: [UUID], day: Int?) {
        writePlanning("Plan", ids) { t in
            t.plannedDay = day
            if day != nil { t.carryCount = 0 }
        }
    }

    /// Run `write` on each task and register ONE undo step restoring the planning fields of every
    /// task it changed (undo and redo both). The step records only `PlanState`, so it is
    /// independent of the whole-row snapshot the other setters use. No change, no step.
    func writePlanning(_ name: String, _ ids: [UUID], _ write: (KTask) -> Void) {
        var changes: [(id: UUID, before: PlanState, after: PlanState)] = []
        for id in ids {
            guard let t = taskIncludingDeleted(id) else { continue }
            let before = PlanState(t)
            write(t)
            let after = PlanState(t)
            guard after != before else { continue }
            t.updatedAt = Date()
            changes.append((id, before, after))
        }
        guard !changes.isEmpty else { return }
        let touched = Set(changes.map(\.id))
        undoStack.append(name, touching: touched) { [weak self] in
            guard let self else { return }
            for c in changes { if let live = self.taskIncludingDeleted(c.id) { c.before.apply(to: live); live.updatedAt = Date() } }
            self.redoStack.append(name, touching: touched) { [weak self] in
                guard let self else { return }
                for c in changes { if let live = self.taskIncludingDeleted(c.id) { c.after.apply(to: live); live.updatedAt = Date() } }
            }
        }
        redoStack.removeAll()
        saveContext()
    }
}

// MARK: - Fresh start

@MainActor
extension TaskStore {

    /// The decision behind the Earlier section of Today: move every task in `ids` to a clean slate
    /// in ONE undo step (one Cmd-Z puts them all back, deadlines and carry included).
    ///
    /// - `.today`: planned for today, carry reset. The deadline stays.
    /// - `.tomorrow`: planned for tomorrow, carry reset. The deadline stays.
    /// - `.someday`: no plan, no deadline, carry reset, status Someday. `originalDueDay` stays.
    ///
    /// Tasks that are gone or closed are skipped. Nothing at all changes, and no step is pushed,
    /// when no task qualifies.
    public func freshStart(ids: [UUID], to target: FreshStartTarget, today: Int = Day.today()) {
        let live = ids.filter { id in task(id).map { KStatus.open.contains($0.status) } ?? false }
        guard !live.isEmpty else { return }
        groupedUndo("Fresh start") {
            switch target {
            case .today:
                writePlanning("Fresh start", live) { $0.plannedDay = today; $0.carryCount = 0 }
            case .tomorrow:
                writePlanning("Fresh start", live) { $0.plannedDay = today + 1; $0.carryCount = 0 }
            case .someday:
                for id in live {
                    update(id) { t in
                        t.dueDay = nil
                        t.status = .someday
                        t.ordoIndex = nil
                    }
                }
                writePlanning("Fresh start", live) { $0.plannedDay = nil; $0.carryCount = 0 }
            }
        }
    }
}
