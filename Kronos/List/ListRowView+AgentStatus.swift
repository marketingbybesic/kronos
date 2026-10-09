// Kronos/List/ListRowView+AgentStatus.swift
// Split out of ListRowView.swift (file-size gate) — the three agent-provenance glyphs that sit in
// the row's inline post-title cluster, sibling to blockedGlyph there: whether this task's
// completion credit belongs to an agent (agentDoneGlyph), it is currently delegated to one and
// still open (delegatedGlyph), or an agent has it in progress right now (workingGlyph, which
// supersedes delegatedGlyph while active). Mutually exclusive by construction (reviewRaw can't be
// both "not yet decided" and "approved/awaitingCheck" at once; a working claim clears itself the
// moment the status leaves in-progress). No colour, no motion, matching every other quiet row glyph.

import SwiftUI
import KronosCore

extension ListRowView {
    /// This task's completion credit belongs to an agent — reviewRaw 2 (person approved) or 4
    /// (done by the agent, awaiting the person's check). "cpu" is registered in Icon.swift's map.
    @ViewBuilder var agentDoneGlyph: some View {
        if task.agentID != nil, task.reviewRaw == ReviewState.approved || task.reviewRaw == ReviewState.awaitingCheck {
            let text = String(format: String(localized: "list.row.agentdone"), agentDisplayName)
            Icon("cpu", size: Metrics.iconXS, weight: .medium)
                .foregroundStyle(Tok.textTertiary)
                .help(text)
                .accessibilityLabel(text)
                .uiTestAnchor("row.agentdone." + task.title)
        }
    }

    /// Sibling to `agentDoneGlyph`, mutually exclusive with it: this task is handed to an agent
    /// and still open — `agentDoneGlyph` takes over the moment the agent's result is in.
    /// "arrowshape.turn.up.right" is a real SF Symbol and resolves raw (contains a dot, so the
    /// UI lint treats it as an already-real symbol name, same as blockedGlyph's "lock.fill").
    @ViewBuilder var delegatedGlyph: some View {
        if task.assigneeRaw == 1, task.agentID != nil,
           task.reviewRaw != ReviewState.approved, task.reviewRaw != ReviewState.awaitingCheck,
           AgentWorkingIndex.shared.claim(for: task) == nil {
            let text = String(format: String(localized: "list.row.delegated"), agentDisplayName)
            Icon("arrowshape.turn.up.right", size: Metrics.iconXS, weight: .medium)
                .foregroundStyle(Tok.textTertiary)
                .help(text)
                .accessibilityLabel(text)
                .uiTestAnchor("row.delegated." + task.title)
        }
    }

    /// This task is currently claimed by an agent's own `update_task status: "inProgress"` in the
    /// last 24h (display-only — nothing is written to clear it; it disappears when the status
    /// leaves in-progress or 24h pass). Supersedes `delegatedGlyph` while active.
    @ViewBuilder var workingGlyph: some View {
        if let c = AgentWorkingIndex.shared.claim(for: task) {
            let text = String(format: String(localized: "list.row.working"), c.name)
            HStack(spacing: Space.x1) {
                Icon("cpu", size: Metrics.iconXS, weight: .medium)
                Circle().fill(Tok.textTertiary).frame(width: Metrics.projectDot, height: Metrics.projectDot)
            }
            .foregroundStyle(Tok.textTertiary)
            .help(text)
            .accessibilityLabel(text)
            .uiTestAnchor("row.working." + task.title)
        }
    }

    var agentDisplayName: String {
        switch InspectorSourceLabel.kind(source: task.source, hasAgentID: task.agentID != nil) {
        case .agent(let name): return name
        case .generic, .none: return String(localized: "review.agent.unnamed")
        }
    }
}
