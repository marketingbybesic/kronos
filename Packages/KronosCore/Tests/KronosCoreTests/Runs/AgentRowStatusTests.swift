#if os(macOS)
import Testing
import Foundation
@testable import KronosCore

/// Hand-written expectation table (rule 26: never derived from the function under test). Each
/// row is independent; several are a deliberate positive control proving the PRECEDING row's
/// winning condition really is what wins (flip one input, the expected case changes).
@Suite struct AgentRowStatusTests {

    private struct Row {
        let name: String
        let hasAgent: Bool
        let reviewRaw: Int
        let isDelegatedAssignee: Bool
        let hasActiveRun: Bool
        let latestRunState: String?
        let expected: AgentRowStatus?
    }

    @Test func resolvesByPrecedenceTable() {
        let none = ReviewState.none, pending = ReviewState.pending, approved = ReviewState.approved
        let rejected = ReviewState.rejected, awaitingCheck = ReviewState.awaitingCheck

        let rows: [Row] = [
            // No agent at all: nothing, regardless of every other flag being "yes".
            Row(name: "no agent at all", hasAgent: false, reviewRaw: awaitingCheck, isDelegatedAssignee: true,
                hasActiveRun: true, latestRunState: "failed", expected: nil),

            // Each state alone, nothing else set.
            Row(name: "active run alone -> running", hasAgent: true, reviewRaw: none, isDelegatedAssignee: false,
                hasActiveRun: true, latestRunState: "running", expected: .running),
            Row(name: "awaitingCheck alone -> readyForReview", hasAgent: true, reviewRaw: awaitingCheck,
                isDelegatedAssignee: false, hasActiveRun: false, latestRunState: nil, expected: .readyForReview),
            Row(name: "latest failed alone -> failed", hasAgent: true, reviewRaw: none, isDelegatedAssignee: false,
                hasActiveRun: false, latestRunState: "failed", expected: .failed),
            Row(name: "latest expired alone -> stale", hasAgent: true, reviewRaw: none, isDelegatedAssignee: false,
                hasActiveRun: false, latestRunState: "expired", expected: .stale),
            Row(name: "delegated assignee alone -> delegated", hasAgent: true, reviewRaw: none,
                isDelegatedAssignee: true, hasActiveRun: false, latestRunState: nil, expected: .delegated),

            // Precedence: running beats every other case even when they are ALSO true.
            Row(name: "running beats readyForReview", hasAgent: true, reviewRaw: awaitingCheck,
                isDelegatedAssignee: true, hasActiveRun: true, latestRunState: "running", expected: .running),
            Row(name: "running beats failed/stale/delegated all at once", hasAgent: true, reviewRaw: none,
                isDelegatedAssignee: true, hasActiveRun: true, latestRunState: "failed", expected: .running),
            // positive control: drop hasActiveRun from the row above, running no longer wins.
            Row(name: "control: same row without an active run -> failed, not running", hasAgent: true,
                reviewRaw: none, isDelegatedAssignee: true, hasActiveRun: false, latestRunState: "failed",
                expected: .failed),

            // readyForReview beats failed/stale/delegated (no active run in play).
            Row(name: "readyForReview beats failed/stale/delegated", hasAgent: true, reviewRaw: awaitingCheck,
                isDelegatedAssignee: true, hasActiveRun: false, latestRunState: "failed", expected: .readyForReview),
            // positive control: drop awaitingCheck, failed wins instead.
            Row(name: "control: same row with reviewRaw none -> failed, not readyForReview", hasAgent: true,
                reviewRaw: none, isDelegatedAssignee: true, hasActiveRun: false, latestRunState: "failed",
                expected: .failed),

            // failed beats stale/delegated.
            Row(name: "failed beats stale/delegated", hasAgent: true, reviewRaw: none, isDelegatedAssignee: true,
                hasActiveRun: false, latestRunState: "failed", expected: .failed),

            // stale beats delegated.
            Row(name: "stale beats delegated", hasAgent: true, reviewRaw: none, isDelegatedAssignee: true,
                hasActiveRun: false, latestRunState: "expired", expected: .stale),
            // positive control: drop the expired state, delegated wins instead.
            Row(name: "control: same row with no run history -> delegated, not stale", hasAgent: true,
                reviewRaw: none, isDelegatedAssignee: true, hasActiveRun: false, latestRunState: nil,
                expected: .delegated),

            // approved excludes delegated (an approved, closed task is never shown as "delegated").
            Row(name: "approved assignee -> nil, not delegated", hasAgent: true, reviewRaw: approved,
                isDelegatedAssignee: true, hasActiveRun: false, latestRunState: nil, expected: nil),

            // A run that ended done/stopped/handoff, not currently delegated: nothing from this ladder
            // (the done-by-agent quiet marker, or nothing, is the app target's job, not this ladder's).
            Row(name: "ended run (done), not delegated -> nil", hasAgent: true, reviewRaw: approved,
                isDelegatedAssignee: false, hasActiveRun: false, latestRunState: "done", expected: nil),
            Row(name: "ended run (stopped), still delegated -> delegated", hasAgent: true, reviewRaw: pending,
                isDelegatedAssignee: true, hasActiveRun: false, latestRunState: "stopped", expected: .delegated),

            // rejected review, no run, not delegated: nothing.
            Row(name: "rejected review alone -> nil", hasAgent: true, reviewRaw: rejected, isDelegatedAssignee: false,
                hasActiveRun: false, latestRunState: nil, expected: nil),
        ]

        for row in rows {
            let got = AgentRowStatusResolver.resolve(hasAgent: row.hasAgent, reviewRaw: row.reviewRaw,
                                                      isDelegatedAssignee: row.isDelegatedAssignee,
                                                      hasActiveRun: row.hasActiveRun, latestRunState: row.latestRunState)
            #expect(got == row.expected, "\(row.name): expected \(String(describing: row.expected)), got \(String(describing: got))")
        }
    }
}
#endif
