// Kronos/Triage/TriageSuggestionMerge.swift
//
// Split out of TriageFlowView.swift so it is pure (no SwiftUI/AppModel dependency) and can be
// compiled + tested standalone by scripts/triage-lock-selftest.swift, same shape as
// TriageQueue.swift and NeighbourTriage.swift.
//
// CONFIRMED ROOT CAUSE of a real bug where using the keyboard would wipe out a field just
// set by hand: TriageFlowView.loadSuggestion() always called
// `router.triage(..., lockedFields: [])` and then unconditionally replaced `suggestion` with
// whatever came back, so a field just set by key or menu click could be overwritten by a
// slower AI reply (or a re-vote from `.onChange(of: model.version)`) landing after the fact.
// `TriageFieldGuard` (Packages/KronosCore/.../AI/TriageFieldGuard.swift) already exists for
// exactly this rule ("triage may ADD fields but never overwrite a field the user already
// set") but was never called from TriageFlowView. This is the same rule applied one layer
// earlier: to the in-flight SUGGESTION shown on the card, not just to what `applyTriage` is
// later allowed to write into the store on Accept.
import KronosCore

enum TriageSuggestionMerge {
    /// Field-by-field merge: a field in `locked` keeps whatever `previous` already had (a
    /// hand-made pick survives every re-vote); every other field takes `fresh`'s value.
    static func apply(_ fresh: TriageResult, over previous: TriageResult?, respecting locked: Set<TriageField>) -> TriageResult {
        guard let previous, !locked.isEmpty else { return fresh }
        return TriageResult(
            project: locked.contains(.project) ? previous.project : fresh.project,
            priority: locked.contains(.priority) ? previous.priority : fresh.priority,
            due: locked.contains(.due) ? previous.due : fresh.due,
            depth: fresh.depth,
            estimateMinutes: fresh.estimateMinutes,
            energyKind: fresh.energyKind,
            firstMove: fresh.firstMove,
            labels: locked.contains(.labels) ? previous.labels : fresh.labels,
            rationale: fresh.rationale,
            proposedRule: fresh.proposedRule,
            effort: locked.contains(.effort) ? previous.effort : fresh.effort,
            reason: fresh.reason,
            version: fresh.version)
    }
}
