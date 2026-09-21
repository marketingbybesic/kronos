// A live probe found `triage.md`'s prompt explained every required field
// EXCEPT `priority`, so the model reliably omitted it from otherwise valid
// JSON. Fixed as a class: every JSON-returning prompt now ends with an
// explicit "Return ONE JSON object with EXACTLY these keys" contract, and
// this file is the guard against the two drifting apart again — required
// keys are declared ONCE here (never in the frozen Contracts/AIDTOs.swift)
// and the drift tests derive both the prompt check and the strict-decode
// check from the same list.

import Foundation

/// The wire-required key names for each JSON-returning prompt's DTO,
/// declared next to the DTO's own `CodingKeys` conceptually but placed here
/// because the DTOs themselves are frozen contract surface. A drift test
/// asserts every string below literally appears in that prompt's system
/// text; another decodes the prompt's own worked example with the same
/// strict decoder callers use, so the example itself can never go stale.
public enum PromptRequiredKeys {
    /// `TriageResult` (triage.md, retriage_with_feedback.md base). Matches
    /// `TriageResult.CodingKeys` minus `proposedRule`, which is retriage-only
    /// and optional (its value may be null, but the key itself is still
    /// asked for explicitly in the retriage addendum).
    public static let triage: [String] = [
        "project", "priority", "due", "depth", "estimateMinutes",
        "energyKind", "firstMove", "labels", "rationale"
    ]

    /// Present as a key on every triage/retriage reply but nullable, unlike
    /// `triage`'s strictly required, non-null keys — kept as its own list so
    /// a drift test can assert the key name appears without asserting it
    /// can never be null.
    public static let triageNullable: [String] = ["effort", "reason"]

    /// Retriage adds exactly one key on top of `triage`.
    public static let retriageAddition: [String] = ["proposedRule"]

    /// `ImpulsRanking.Entry` (impuls_pick.md).
    public static let impulsPickEntry: [String] = ["position", "mentorLine"]

    /// `OrdoResort` (ordo_resort.md).
    public static let ordoResort: [String] = ["order", "explanation", "proposedRule"]

    /// The breakdown DTO's wire shape, wired into
    /// `AIRouting.breakdown`.
    public static let breakdown: [String] = ["subtasks", "firstMove"]

    /// The extract DTO's wire shape.
    /// One task's required keys; `tasks` itself (the envelope) is required
    /// too but is checked separately since it wraps an array, not a scalar.
    public static let extractTask: [String] = ["title", "priority", "effort", "sourceLine"]
    public static let extract: [String] = ["tasks"]
}
