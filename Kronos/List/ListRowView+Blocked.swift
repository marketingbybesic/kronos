// Kronos/List/ListRowView+Blocked.swift
// Split out of ListRowView.swift (file-size gate) — the row's "waits on an open task" glyph,
// sibling to the agent-provenance ones in ListRowView+AgentStatus.swift. Same resolve-the-
// text-once/render-the-icon split: `ListRowView.swift`'s `row` resolves `blockedAccessibilityText`
// exactly once per row and hands it to both this glyph's tooltip and the row's one composed
// `accessibilityValue` — `KListRow` folds the row into ONE accessibility element
// (`.accessibilityElement(children: .ignore)`), so the icon's own `.accessibilityLabel` below is
// never read by VoiceOver on its own; see ListRowView+AgentStatus.swift's header for the full
// reasoning (same split, same reason, one more glyph).
import SwiftUI
import KronosCore

extension ListRowView {
    /// A lock after the title while the task still waits on open tasks; the tooltip names the one
    /// it waits on, or counts them. Gone as soon as the last open blocker is done or removed.
    /// `text` is `blockedAccessibilityText`.
    @ViewBuilder func blockedGlyph(text: String?) -> some View {
        if let text {
            Icon("lock.fill", size: Metrics.iconXS, weight: .medium)
                .foregroundStyle(Tok.textSecondary)
                .help(text)
                .accessibilityLabel(text)
                .uiTestAnchor("row.blocked." + task.title)
        }
    }

    /// `blockedGlyph`'s text, nil when the task has no open blocker. `TaskStore.openBlockers`
    /// only scans the whole store once `task.waitsOnIDs` is non-empty, so this stays cheap for
    /// the common case; `row` calls it exactly once per row.
    var blockedAccessibilityText: String? {
        let _ = model.version   // blockers are other tasks: re-read after any store change
        let blockers = KStatus.open.contains(task.status) ? model.store.openBlockers(of: task.id) : []
        guard !blockers.isEmpty else { return nil }
        return blockers.count == 1
            ? String(format: String(localized: "list.row.blocked.one"), blockers[0].waitsOnDisplayName)
            : String(format: String(localized: "list.row.blocked.many"), blockers.count)
    }
}
