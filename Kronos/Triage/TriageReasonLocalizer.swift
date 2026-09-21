// Kronos/Triage/TriageReasonLocalizer.swift
//
// `NeighbourTriage.reason(for:count:)` (KronosCore, Foundation-only, ships no strings) always
// returns one of exactly two fixed English shapes — "Like N similar X tasks" / "Like N similar
// tasks already in your list" — because Core cannot depend on the app's Localizable.xcstrings
// (spec §1). Rather than re-glue that rule by giving Core a language parameter (a much larger
// change touching every TriageResult.reason producer, see TaskStore.swift's own GAP note on the
// same tradeoff), this call site PARSES the fixed shape back into (count, project?) and renders
// it through the catalog with Croatian one/few/many, exactly like KPlural.hr everywhere else.
// AI-sourced reasons are arbitrary text already in the task's own language (spec §1's
// independent axis) and are shown as-is — parsing requires the WHOLE string to match one of
// the two fixed shapes, so a coincidental AI string that also starts with "Like" is never
// touched. Plain string operations, not a regex literal: portable (no toolchain-specific
// regex-literal parsing mode to depend on) and this shape is simple enough not to need one.
// Foundation-only by design so scripts/triage-reason-selftest.swift can compile it standalone
// (same shape as Kronos/Shared/KPluralCategory.swift).
import Foundation

private let genericSuffix = " tasks already in your list"

/// Parses "Like N similar tasks already in your list" -> N, or nil if `reason` is not that
/// exact shape (extra/missing words, wrong casing, a project name present instead).
private func parseGenericShape(_ reason: String) -> Int? {
    guard reason.hasPrefix("Like "), reason.hasSuffix(genericSuffix) else { return nil }
    let middle = reason.dropFirst("Like ".count).dropLast(genericSuffix.count)
    guard middle.hasSuffix(" similar") else { return nil }
    return Int(middle.dropLast(" similar".count))
}

/// Parses "Like N similar PROJECT tasks" -> (N, PROJECT), or nil if not that exact shape.
/// PROJECT is whatever sits between "similar " and " tasks" and is non-empty and not itself
/// "tasks already in your list" (that is the generic shape, checked first by the caller).
private func parseProjectShape(_ reason: String) -> (Int, String)? {
    guard reason.hasPrefix("Like "), reason.hasSuffix(" tasks") else { return nil }
    let middle = reason.dropFirst("Like ".count).dropLast(" tasks".count)
    let parts = middle.split(separator: " ", maxSplits: 1)
    guard parts.count == 2, let count = Int(parts[0]), parts[1].hasPrefix("similar ") else { return nil }
    let project = parts[1].dropFirst("similar ".count)
    guard !project.isEmpty else { return nil }
    return (count, String(project))
}

func localizedNeighbourReason(_ reason: String, isNeighbourSourced: Bool) -> String {
    guard isNeighbourSourced else { return reason }
    let isCroatian = KronosLocale.languageCode == "hr"
    if let count = parseGenericShape(reason) {
        let pattern: String
        switch KPluralCategory.category(for: count, isCroatian: isCroatian) {
        case .one: pattern = String(localized: "triage.reason.similar_generic.one")
        case .few: pattern = String(localized: "triage.reason.similar_generic.few")
        case .many: pattern = String(localized: "triage.reason.similar_generic.many")
        }
        return String(format: pattern, count)
    }
    // KPlural.hr only ever substitutes ONE %lld into its own literal pattern; the project-name
    // shape needs a second %@ argument, so the category is picked the same way KPlural does
    // internally and formatted here with both arguments (same shape as
    // QuickAddPanelView.swift's subtaskSummary, for the same reason).
    if let (count, project) = parseProjectShape(reason) {
        let pattern: String
        switch KPluralCategory.category(for: count, isCroatian: isCroatian) {
        case .one: pattern = String(localized: "triage.reason.similar_project.one")
        case .few: pattern = String(localized: "triage.reason.similar_project.few")
        case .many: pattern = String(localized: "triage.reason.similar_project.many")
        }
        return String(format: pattern, count, project)
    }
    return reason
}
