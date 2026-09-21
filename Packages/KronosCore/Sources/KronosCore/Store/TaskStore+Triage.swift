// KronosCore/Store — see Contracts/TaskStoring.swift.
//
// `applyTriage`: writes a `TriageResult` onto a task, filling ONLY the
// fields that are still empty (coach principle 7: "everything the coach
// fills is visibly marked and undoable in one step"). An extension on the
// `TaskStoring` PROTOCOL, not on the concrete `TaskStore` class, because
// every operation it needs (`task(_:)`, `update`, `groupedUndo`,
// `label(named:)`, `addLabel`) is already public protocol surface — there is
// no reason to reach into `TaskStore`'s internals, and writing it this way
// means any future `TaskStoring` conformer (a preview/mock store, say) gets
// `applyTriage` for free.

import Foundation

/// Which of a task's fields `applyTriage` is allowed to consider. Mirrors
/// `TriageField` (AI/TriageFieldGuard.swift) but is its own type: that one is
/// about LOCKING fields the user set explicitly, this one is about which
/// fields a triage RESULT can affect at all — project/priority/due/depth/
/// estimate/energyKind/firstMove/labels/effort. Kept separate so a change to
/// one enum's cases can never silently change the other's meaning.
public enum TriageFieldKind: String, CaseIterable, Sendable {
    case project, priority, due, depth, estimateMinutes, energyKind, firstMove, labels, effort
}

extension TaskStoring {

    /// Apply `result` to task `id`.
    ///
    /// - Parameter fillOnly: when true (the default, and the only mode the
    ///   spec calls for — "fills ONLY empty fields"), a field is written
    ///   only when the task's current value is the empty/unset state for
    ///   that field. `false` is kept for a future explicit "Accept all"
    ///   action the UI does not build yet; it overwrites unconditionally.
    /// - Returns: exactly which fields were written, so the caller can show
    ///   "filled: priority, effort" — the visible mark coach principle 7
    ///   requires. Empty when the task does not exist or nothing was empty.
    ///
    /// REGISTERS UNDO: one `groupedUndo` step for the whole call, however
    /// many fields it touches — Cmd-Z undoes the triage as one action.
    /// Marks `needsTriage = false` inside the SAME step whenever the task
    /// existed, even if every field was already filled (a re-triage that
    /// changes nothing still means "triage has now looked at this row").
    @discardableResult
    public func applyTriage(_ result: TriageResult, to id: UUID, fillOnly: Bool = true,
                            only allowed: Set<TriageFieldKind>? = nil) -> [TriageFieldKind] {
        guard let current = task(id) else { return [] }
        var filled: [TriageFieldKind] = []

        func isEmpty(_ field: TriageFieldKind) -> Bool {
            switch field {
            case .project:         return current.project == nil
            case .priority:        return current.priority == .none
            case .due:              return current.dueDay == nil
            case .depth:            return current.depth == .unknown
            case .estimateMinutes: return current.estimateMinutes == nil
            case .energyKind:      return current.energyKind == nil
            case .firstMove:       return current.firstMove == nil
            case .labels:           return (current.labels ?? []).isEmpty
            case .effort:           return current.effort == .none
            }
        }
        // `allowed` = the fields the user lets the coach touch (Settings > Coach); nil = all.
        func mayWrite(_ field: TriageFieldKind) -> Bool {
            (allowed?.contains(field) ?? true) && (!fillOnly || isEmpty(field))
        }

        groupedUndo("Triage") {
            if mayWrite(.project), let name = result.project {
                if let match = allProjects().first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                    update(id) { $0.project = match; $0.projectID = match.id
                                 $0.areaID = match.area?.id; $0.isProjectArchived = match.isArchived }
                    filled.append(.project)
                }
            }
            if mayWrite(.priority), result.priority > 0 {
                if let p = KPriority(rawValue: result.priority) {
                    update(id) { $0.priorityRaw = p.rawValue }
                    filled.append(.priority)
                }
            }
            if mayWrite(.due), let due = result.due, let day = Day.parseISO(due) {
                update(id) { t in
                    t.dueDay = day
                    if t.originalDueDay == nil { t.originalDueDay = day }
                }
                filled.append(.due)
            }
            if mayWrite(.depth) {
                update(id) { $0.depthRaw = result.depth.kDepth.rawValue }
                filled.append(.depth)
            }
            if mayWrite(.estimateMinutes) {
                update(id) { $0.estimateMinutes = result.estimateMinutes }
                filled.append(.estimateMinutes)
            }
            if mayWrite(.energyKind) {
                update(id) { $0.energyKindRaw = result.energyKind.kEnergyKind.rawValue }
                filled.append(.energyKind)
            }
            if mayWrite(.firstMove), !result.firstMove.isEmpty {
                update(id) { $0.firstMove = result.firstMove }
                filled.append(.firstMove)
            }
            if mayWrite(.labels), !result.labels.isEmpty {
                for name in result.labels {
                    let label = label(named: name)
                    addLabel(label, to: id)
                }
                filled.append(.labels)
            }
            if mayWrite(.effort), let effort = result.effort, effort != .none {
                update(id) { $0.effortRaw = effort.rawValue }
                filled.append(.effort)
            }
            update(id) { t in
                t.needsTriage = false
                t.triageRationale = result.rationale.isEmpty ? t.triageRationale : result.rationale
                t.triagedAt = Date()
            }
        }
        return filled
    }
}
