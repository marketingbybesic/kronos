import Testing
import Foundation
@testable import KronosCore

/// Guards against a prompt that explains every required field except one,
/// so a model reliably returns complete, valid (`finish_reason: "stop"`)
/// JSON that is simply missing it. Two checks per prompt close this
/// permanently:
///   1. every required key name is textually present in the prompt's system
///      block (so a future edit that drops a key's explanation is caught);
///   2. the prompt's own worked example decodes with the same strict
///      decoder callers use (so a stale or malformed example is caught).
struct PromptDriftTests {

    // MARK: Triage / retriage

    @Test func triagePromptNamesEveryRequiredKey() {
        for key in PromptRequiredKeys.triage {
            #expect(PromptTemplates.triageSystem.contains(key), "triage.md missing key: \(key)")
        }
    }

    @Test func triagePromptExampleDecodesStrictly() throws {
        let example = try extractExample(from: PromptTemplates.triageSystem)
        let decoded: TriageResult = try OutputExtraction.decode(TriageResult.self, from: example)
        #expect(!decoded.firstMove.isEmpty)
    }

    /// `effort`/`reason` are present-but-nullable keys, checked separately from `triage`'s
    /// strictly-required list — this only asserts the NAME appears, since nullability itself
    /// is exercised by `AIDTOs`' tolerant decode.
    @Test func triagePromptNamesTheNullableKeysToo() {
        for key in PromptRequiredKeys.triageNullable {
            #expect(PromptTemplates.triageSystem.contains(key), "triage.md missing nullable key: \(key)")
        }
    }

    @Test func triageUserTemplateHasAnExamplesPlaceholder() {
        #expect(PromptTemplates.triageUserTemplate.contains("{{EXAMPLES}}"))
    }

    @Test func retriagePromptNamesEveryRequiredKeyIncludingProposedRule() {
        let full = PromptTemplates.retriageSystem
        for key in PromptRequiredKeys.triage + PromptRequiredKeys.retriageAddition {
            #expect(full.contains(key), "retriage prompt missing key: \(key)")
        }
    }

    @Test func retriagePromptExampleDecodesStrictly() throws {
        // The retriage addendum's own example (its LAST fenced-less JSON
        // object) must include proposedRule and still decode as a
        // TriageResult, since retriage reuses the same DTO.
        let example = try extractExample(from: PromptTemplates.retriageSystemAddendum)
        let decoded: TriageResult = try OutputExtraction.decode(TriageResult.self, from: example)
        #expect(decoded.proposedRule != nil)
    }

    // MARK: Impuls pick

    @Test func impulsPickPromptNamesEveryRequiredKey() {
        for key in PromptRequiredKeys.impulsPickEntry {
            #expect(PromptTemplates.impulsPickSystem.contains(key), "impuls_pick.md missing key: \(key)")
        }
    }

    @Test func impulsPickPromptExampleDecodesStrictly() throws {
        let example = try extractExample(from: PromptTemplates.impulsPickSystem)
        let decoded: ImpulsRanking = try OutputExtraction.decode(ImpulsRanking.self, from: example)
        #expect(!decoded.ranked.isEmpty)
        #expect(decoded.isValid(candidateCount: decoded.ranked.map(\.position).max() ?? 0))
    }

    // MARK: Ordo resort

    @Test func ordoResortPromptNamesEveryRequiredKey() {
        for key in PromptRequiredKeys.ordoResort {
            #expect(PromptTemplates.ordoResortSystem.contains(key), "ordo_resort.md missing key: \(key)")
        }
    }

    @Test func ordoResortPromptExampleDecodesStrictly() throws {
        let example = try extractExample(from: PromptTemplates.ordoResortSystem)
        let decoded: OrdoResort = try OutputExtraction.decode(OrdoResort.self, from: example)
        #expect(decoded.isValid(queueCount: decoded.order.count))
    }

    // MARK: Breakdown (no AIRouting caller yet, but one of the five prompts)

    private struct BreakdownExample: Decodable {
        let subtasks: [String]
        let firstMove: String
    }

    @Test func breakdownPromptNamesEveryRequiredKey() {
        for key in PromptRequiredKeys.breakdown {
            #expect(PromptTemplates.breakdownSystem.contains(key), "breakdown.md missing key: \(key)")
        }
    }

    @Test func breakdownPromptExampleDecodesStrictly() throws {
        let example = try extractExample(from: PromptTemplates.breakdownSystem)
        let decoded: BreakdownExample = try OutputExtraction.decode(BreakdownExample.self, from: example)
        #expect((3...7).contains(decoded.subtasks.count))
        #expect(!decoded.firstMove.isEmpty)
    }

    // MARK: Helper

    /// Every prompt's contract block ends with one worked example object
    /// immediately before the final "Return a single JSON object..." line.
    /// `OutputExtraction.braceSlice` finds the first `{` to the last `}` in
    /// the WHOLE prompt, which would wrongly span from the "Good:"/"Bad:"
    /// sample strings through the real example — so this pulls out only the
    /// text after the "Example (values are illustrative" marker first.
    private func extractExample(from prompt: String) throws -> String {
        guard let marker = prompt.range(of: "Example (values are illustrative") else {
            throw AIError.badJSON(prefix: "no worked example found in prompt")
        }
        let tail = String(prompt[marker.upperBound...])
        let sliced = OutputExtraction.braceSlice(tail)
        return sliced
    }
}
