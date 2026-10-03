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

    /// Decodes a stored comma-joined list (`KTask.lockedFieldsRaw`, `triageFilledFieldsRaw`):
    /// unknown or empty pieces are dropped, duplicates removed, the canonical order kept.
    public static func parse(_ raw: String) -> [TriageFieldKind] {
        let names = Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        return allCases.filter { names.contains($0.rawValue) }
    }

    /// The stored form: canonical order, comma-joined, no duplicates. Empty set -> "".
    public static func encode<S: Sequence>(_ fields: S) -> String where S.Element == TriageFieldKind {
        let set = Set(fields)
        return allCases.filter(set.contains).map(\.rawValue).joined(separator: ",")
    }
}

extension KTask {
    /// Fields a person or an agent set explicitly. Triage never writes them, even when empty
    /// (an explicit "no priority" stays no priority).
    public var lockedFields: Set<TriageFieldKind> { Set(TriageFieldKind.parse(lockedFieldsRaw)) }

    /// The fields the last triage filled and still owns: what Discard reverts.
    public var triageFilledFields: [TriageFieldKind] { TriageFieldKind.parse(triageFilledFieldsRaw) }
}

/// A first move that only repeats the task title ("Review: <title>", or the title itself) adds no
/// step: triage leaves the field empty instead so the inspector shows its hint.
public enum FirstMoveRestatement {
    public static func restates(_ move: String, title: String) -> Bool {
        func norm(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: ".:;"))
        }
        var m = norm(move)
        let t = norm(title)
        guard !t.isEmpty else { return false }
        for prefix in ["review:", "pregledaj:", "review ", "pregledaj "] where m.hasPrefix(prefix) {
            m = norm(String(m.dropFirst(prefix.count)))
            break
        }
        return m == t || (m.count >= 12 && t.contains(m)) || (t.count >= 12 && m.contains(t))
    }
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
    /// `result.dread == true` sets the dread flag in the same step (set only,
    /// never cleared); it is not one of the returned fields.
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
        let locked = current.lockedFields
        func mayWrite(_ field: TriageFieldKind) -> Bool {
            // A subtask takes its project from its parent; triage never files it elsewhere.
            if field == .project && current.isSubtask { return false }
            // Set explicitly by a person or an agent: never overwritten, not even when empty.
            if locked.contains(field) { return false }
            return (allowed?.contains(field) ?? true) && (!fillOnly || isEmpty(field))
        }

        // A task whose every field was set explicitly (an agent that decided everything) keeps its
        // dread flag as written too, and so does one the person switched off by hand.
        let setsDread = result.dread == true && !current.dread
            && !locked.isSuperset(of: TriageFieldKind.allCases) && !current.dreadLocked

        groupedUndo("Sort") {
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
            if mayWrite(.firstMove), !result.firstMove.isEmpty,
               !FirstMoveRestatement.restates(result.firstMove, title: current.title) {
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
                // The model judged the task one the person is likely to avoid. Set only, never
                // cleared: a model that says nothing (or "no") leaves the flag as it is, and an
                // explicit fill-everything pass may set it too.
                if setsDread { t.dread = true }
                t.needsTriage = false
                t.triageRationale = result.rationale.isEmpty ? t.triageRationale : result.rationale
                t.triagedAt = Date()
            }
        }
        return filled
    }

    // MARK: - Locks and provenance

    /// The fields of task `id` that triage must never write. Empty for an unknown id.
    public func lockedFields(of id: UUID) -> Set<TriageFieldKind> {
        taskIncludingDeleted(id)?.lockedFields ?? []
    }

    /// Marks `field` of task `id` as set explicitly (by the user in the UI, or by an agent that
    /// passed the field, including an explicit "none"). From then on triage never writes it, and
    /// a later Discard of the last fill no longer reverts it: the value is the person's now.
    /// Bookkeeping, not an edit: pushes no undo step, and does nothing when already locked.
    public func lockField(_ field: TriageFieldKind, on id: UUID) {
        guard let t = taskIncludingDeleted(id) else { return }
        let filled = t.triageFilledFields
        guard !t.lockedFields.contains(field) || filled.contains(field) else { return }
        updateNoUndo(id) { t in
            t.lockedFieldsRaw = TriageFieldKind.keepingDreadToken(from: t.lockedFieldsRaw,
                                                                  in: TriageFieldKind.encode(t.lockedFields.union([field])))
            t.triageFilledFieldsRaw = TriageFieldKind.encode(filled.filter { $0 != field })
        }
    }

    /// Records what the last triage filled on task `id` (the list `applyTriage` returned) and
    /// which model filled it. Replaces the previous record. Locked fields are never recorded.
    /// Provenance, not an edit: pushes no undo step.
    public func recordTriageFill(task id: UUID, fields: [TriageFieldKind], model: String?) {
        guard let t = taskIncludingDeleted(id) else { return }
        let raw = TriageFieldKind.encode(fields.filter { !t.lockedFields.contains($0) })
        guard t.triageFilledFieldsRaw != raw || t.triageModel != model else { return }
        updateNoUndo(id) { t in
            t.triageFilledFieldsRaw = raw
            t.triageModel = model
        }
    }

    /// Discard: clears exactly the fields the last triage filled and still owns (anything typed
    /// since, a title for instance, stays), then forgets the record. One undo step. Returns the
    /// fields it cleared; empty when there was no record.
    @discardableResult
    public func revertTriageFill(task id: UUID) -> [TriageFieldKind] {
        guard let current = taskIncludingDeleted(id) else { return [] }
        let fields = current.triageFilledFields.filter { !current.lockedFields.contains($0) }
        guard !fields.isEmpty || !current.triageFilledFieldsRaw.isEmpty else { return [] }
        groupedUndo("Sort") {
            if fields.contains(.labels) {
                for label in current.labels ?? [] { removeLabel(label, from: id) }
            }
            updateIncludingDeleted(id) { t in
                for field in fields {
                    switch field {
                    case .project:
                        t.project = nil; t.projectID = nil; t.areaID = nil; t.isProjectArchived = false
                    case .priority:        t.priorityRaw = KPriority.none.rawValue
                    case .due:
                        // Triage set the original deadline only when there was none.
                        if t.originalDueDay == t.dueDay { t.originalDueDay = nil }
                        t.dueDay = nil
                    case .depth:           t.depthRaw = KDepth.unknown.rawValue
                    case .estimateMinutes: t.estimateMinutes = nil
                    case .energyKind:      t.energyKindRaw = nil
                    case .firstMove:       t.firstMove = nil
                    case .labels:          break
                    case .effort:          t.effortRaw = KEffort.none.rawValue
                    }
                }
                t.triageFilledFieldsRaw = ""
                t.triageModel = nil
            }
        }
        return fields
    }
}
