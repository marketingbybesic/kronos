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
    /// ≤2-minute opener. REGISTERS UNDO.
    public func setDread(_ id: UUID, _ dread: Bool) {
        update(id) { $0.dread = dread }
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
        guard let t = task(id) else { return }
        let target: KStatus = waiting ? .waiting : (t.dueDay != nil ? .todo : .someday)
        guard t.status != target else { return }
        setStatus(id, target)
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
