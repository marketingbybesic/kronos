// Kronos/List/ListRowView+AgentStatus.swift
// Split out of ListRowView.swift (file-size gate) — the row's agent-provenance glyphs, sibling
// to blockedGlyph in ListRowView+Blocked.swift (same split, same file-size reason). `agentStatusGlyph`
// ListRowView.swift actually mounts: a pure precedence ladder (AgentRowStatusResolver,
// KronosCore, hand-table tested) picks at most ONE of running / ready-for-review / failed /
// stale / delegated, read live off `RunStore` through `model.runs`. `agentDoneGlyph` is its
// separate, lower-priority quiet fallback: once a task is reviewRaw == approved (closed,
// reviewed), none of the five ladder states can be true, so the two never compete for the same
// row in practice — they just don't share one switch, since "done" is a permanent provenance
// record, not a status competing for attention.
//
// Both glyphs follow the same resolve-the-text-once/render-the-icon split as this file's
// `blockedGlyph`/`blockedAccessibilityText`: `ListRowView.swift`'s `row` resolves
// `agentDoneAccessibilityText`/`agentStatus` exactly once per row and feeds the SAME text to
// both the glyph's tooltip and the row's one composed `accessibilityValue`. That is not just a
// cache — `KListRow` folds the whole row into ONE accessibility element
// (`.accessibilityElement(children: .ignore)`), so a glyph's own `.accessibilityLabel` below is
// never read by VoiceOver on its own; `accessibilityValue` is the only thing that reaches it.
import SwiftUI
import KronosCore

extension ListRowView {
    /// This task's completion credit belongs to an agent — reviewRaw 2 (person approved). The
    /// "awaiting the person's check" case (reviewRaw 4) moved to `agentStatusGlyph`'s
    /// `.readyForReview` case, which reads as a call to action, not a quiet past-tense record.
    /// "cpu" is registered in Icon.swift's map. `text` is `agentDoneAccessibilityText`.
    @ViewBuilder func agentDoneGlyph(text: String?) -> some View {
        if let text {
            Icon("cpu", size: Metrics.iconXS, weight: .medium)
                .foregroundStyle(Tok.textTertiary)
                .help(text)
                .accessibilityLabel(text)
                .uiTestAnchor("row.agentdone." + task.title)
        }
    }

    /// `agentDoneGlyph`'s text, nil unless this task's completion credit belongs to an agent
    /// (reviewRaw == approved). `row` calls it exactly once per row.
    var agentDoneAccessibilityText: String? {
        guard task.agentID != nil, task.reviewRaw == ReviewState.approved else { return nil }
        return String(format: String(localized: "list.row.agentdone"), agentDisplayName)
    }

    /// The one agent-status glyph this row shows, by precedence (plan C1): running beats
    /// ready-for-review beats failed beats stale beats delegated. `AgentRowStatusResolver`
    /// (KronosCore, pure, hand-table tested) decides WHICH; this resolves the live run data the
    /// pure function cannot see (which agent, for the a11y label) plus the copy for whichever
    /// case it picked — ONCE. `row` reads `.text` for the composed accessibility value and hands
    /// the whole result to `agentStatusGlyph` so a live run lookup (`model.runs`, a SwiftData
    /// fetch) never runs twice per row.
    var agentStatus: AgentRowStatusResolved? {
        let _ = model.version   // runs change via MCP/the harness: re-read after any store change
        let activeRun = model.runs?.activeRun(taskID: task.id)
        let latestRun = model.runs?.runs(taskID: task.id).first
        guard let kind = AgentRowStatusResolver.resolve(
            hasAgent: task.agentID != nil, reviewRaw: task.reviewRaw,
            isDelegatedAssignee: task.assigneeRaw == 1 && task.agentID != nil,
            hasActiveRun: activeRun != nil, latestRunState: latestRun?.stateRaw) else { return nil }
        let text: String
        switch kind {
        case .running:
            text = String(format: String(localized: "list.row.running"), RunAgentNaming.displayName(forSlug: activeRun?.agentSlug ?? ""))
        case .readyForReview:
            text = String(localized: "list.row.readyforreview")
        case .failed:
            text = String(format: String(localized: "list.row.runfailed"), RunAgentNaming.displayName(forSlug: latestRun?.agentSlug ?? ""))
        case .stale:
            text = String(format: String(localized: "list.row.stale"), RunAgentNaming.displayName(forSlug: latestRun?.agentSlug ?? ""))
        case .delegated:
            text = String(format: String(localized: "list.row.delegated"), agentDisplayName)
        }
        return AgentRowStatusResolved(kind: kind, text: text)
    }

    /// Renders whichever case `agentStatus` already resolved — pure rendering (icon, colour,
    /// `uiTestAnchor`) off the pre-resolved text, no second `model.runs` lookup. The `.delegated`
    /// case folds in what used to be a separate `delegatedGlyph`: it was only ever reached from
    /// here, and `agentStatus` already applied its guard (`isDelegatedAssignee`, `reviewRaw` not
    /// approved/awaitingCheck) while resolving the ladder, so a second guard here would be dead.
    @ViewBuilder func agentStatusGlyph(_ resolved: AgentRowStatusResolved?) -> some View {
        if let resolved {
            switch resolved.kind {
            case .running:
                AgentRunningGlyph(text: resolved.text)
                    .uiTestAnchor("row.running." + task.title)
            case .readyForReview:
                Icon("badge-check", size: Metrics.iconXS, weight: .medium)
                    .foregroundStyle(Tok.textTertiary)
                    .help(resolved.text)
                    .accessibilityLabel(resolved.text)
                    .uiTestAnchor("row.readyforreview." + task.title)
            case .failed:
                Icon("alert-circle", size: Metrics.iconXS, weight: .medium)
                    .foregroundStyle(Tok.textTertiary)
                    .help(resolved.text)
                    .accessibilityLabel(resolved.text)
                    .uiTestAnchor("row.runfailed." + task.title)
            case .stale:
                Icon("clock-alert", size: Metrics.iconXS, weight: .medium)
                    .foregroundStyle(Tok.textTertiary)
                    .help(resolved.text)
                    .accessibilityLabel(resolved.text)
                    .uiTestAnchor("row.stale." + task.title)
            case .delegated:
                Icon("arrowshape.turn.up.right", size: Metrics.iconXS, weight: .medium)
                    .foregroundStyle(Tok.textTertiary)
                    .help(resolved.text)
                    .accessibilityLabel(resolved.text)
                    .uiTestAnchor("row.delegated." + task.title)
            }
        } else {
            EmptyView()
        }
    }

    var agentDisplayName: String {
        switch InspectorSourceLabel.kind(source: task.source, hasAgentID: task.agentID != nil) {
        case .agent(let name): return name
        case .generic, .none: return String(localized: "review.agent.unnamed")
        }
    }
}

/// `agentStatus`'s resolved value for one row: which case the precedence ladder picked
/// (`AgentRowStatusResolver`'s pure `AgentRowStatus`) plus the copy already formatted for it
/// (which agent, etc.) — bundled so `agentStatusGlyph` never re-reads `model.runs` or
/// re-formats `RunAgentNaming.displayName` to render what `agentStatus` already decided.
struct AgentRowStatusResolved {
    let kind: AgentRowStatus
    let text: String
}

/// `agentStatusGlyph`'s `.running` case: cpu + a slow pulsing dot (plan C1: opacity 0.4↔1.0,
/// 1.6s via `Motion.breathLoop`; static under Reduce Motion). A dedicated view, not an
/// extension computed property, because the pulse needs its own `@State` — an extension cannot
/// add a stored property to `ListRowView` itself.
private struct AgentRunningGlyph: View {
    let text: String
    @State private var isPulsing = false

    var body: some View {
        HStack(spacing: Space.x1) {
            Icon("cpu", size: Metrics.iconXS, weight: .medium)
            Circle()
                .fill(Tok.textTertiary)
                .frame(width: Metrics.projectDot, height: Metrics.projectDot)
                .opacity(Motion.reduceMotion ? 1 : (isPulsing ? 1.0 : 0.4))
        }
        .foregroundStyle(Tok.textTertiary)
        .help(text)
        .accessibilityLabel(text)
        .onAppear {
            guard !Motion.reduceMotion else { return }
            withAnimation(.easeInOut(duration: Motion.breathLoop).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }
}
