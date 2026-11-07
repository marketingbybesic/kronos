// Kronos v1.2 Phase 2 slice C: which single agent-status glyph (if any) a task row shows, by
// precedence. Pure value function — no SwiftUI, no SwiftData fetch — so the ladder itself is
// hand-table tested here; Kronos/List/ListRowView+AgentStatus.swift (app target) only resolves
// the icon/colour/string for whatever case this returns and is otherwise untested (UI only).
//
// The "completed by <agent>" quiet provenance marker (reviewRaw == approved) is deliberately
// NOT part of this ladder: it is a permanent record on a CLOSED task, not a status competing for
// attention, and by construction never coexists with any case below (approved implies no active
// run and reviewRaw != awaitingCheck — a done, reviewed task cannot also be mid-run). The app
// target keeps it as a separate, lower-priority fallback (ListRowView+AgentStatus.swift's
// `agentDoneGlyph`, narrowed to that one case).
import Foundation

/// One row's agent-status glyph, in precedence order (plan Phase 2 slice C1): `running` beats
/// `readyForReview` beats `failed` beats `stale` beats `delegated`.
public enum AgentRowStatus: Equatable, Sendable {
    case running
    case readyForReview
    case failed
    case stale
    case delegated
}

public enum AgentRowStatusResolver {
    /// - Parameters:
    ///   - hasAgent: `task.agentID != nil` — no agent association at all means no glyph here.
    ///   - reviewRaw: `task.reviewRaw` (`ReviewState` raw values).
    ///   - isDelegatedAssignee: `task.assigneeRaw == 1 && task.agentID != nil` (the existing
    ///     "handed to an agent, still open" signal `delegatedGlyph` already reads).
    ///   - hasActiveRun: `RunStore.activeRun(taskID:) != nil` — state `running` AND its lease has
    ///     not yet passed. Checked separately from `latestRunState` because the two can briefly
    ///     disagree: a run whose lease just passed is no longer "active" even though nothing has
    ///     swept it to `expired` yet — that gap resolves to no glyph here, not `stale`, until a
    ///     sweep catches up (never `running`, by `hasActiveRun`'s own definition).
    ///   - latestRunState: the most recently STARTED run's `KAgentRun.stateRaw`
    ///     (running|done|failed|stopped|expired|handoff), or nil when the task has no run at all.
    public static func resolve(hasAgent: Bool, reviewRaw: Int, isDelegatedAssignee: Bool,
                                hasActiveRun: Bool, latestRunState: String?) -> AgentRowStatus? {
        guard hasAgent else { return nil }
        if hasActiveRun { return .running }
        if reviewRaw == ReviewState.awaitingCheck { return .readyForReview }
        if latestRunState == "failed" { return .failed }
        if latestRunState == "expired" { return .stale }
        if isDelegatedAssignee, reviewRaw != ReviewState.approved { return .delegated }
        return nil
    }
}
