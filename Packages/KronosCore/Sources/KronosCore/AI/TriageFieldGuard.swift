// The rule: triage may ADD fields but never
// overwrite a field the user (or quick-add) already set.
//
// This layer owns no store access (that is `TaskStoring`), so the guard
// lives here as a pure function: given a decoded `TriageResult` and the set
// of field names the caller has already locked, it returns only the subset
// of fields that are safe to write. The caller (L5/L6, via a `…NoUndo`
// `TaskStoring` method) applies exactly that subset and nothing else.

import Foundation

/// The triage field names a caller can lock, matching `TriageResult`'s wire
/// fields. String-keyed rather than an enum so a caller's own field-name
/// constants (defined outside this leaf's ownership) can be compared by
/// value without importing an enum from here.
public enum TriageField: String, CaseIterable, Sendable {
    case project, priority, due, depth, estimateMinutes, energyKind, firstMove, labels, rationale
    /// The user's coarse sizing.
    case effort
}

/// The result of applying the lock guard: which of `TriageResult`'s fields
/// survive for writing, keyed by `TriageField`.
public struct GuardedTriageResult: Sendable {
    public let allowed: Set<TriageField>
    public let result: TriageResult

    /// True when this field's value from `result` should be written.
    public func mayWrite(_ field: TriageField) -> Bool { allowed.contains(field) }
}

public enum TriageFieldGuard {
    /// Every `TriageResult` field is present in `result` unconditionally (it
    /// is a value type — there is no way to "omit" a field once decoded), so
    /// the guard's only job is to say which of them the caller may apply.
    /// Any field named in `lockedFields` is excluded; everything else is
    /// allowed, because triage may ADD fields but never overwrite what the
    /// user or quick-add already set.
    public static func apply(_ result: TriageResult, lockedFields: Set<TriageField>) -> GuardedTriageResult {
        let allowed = Set(TriageField.allCases).subtracting(lockedFields)
        return GuardedTriageResult(allowed: allowed, result: result)
    }
}
