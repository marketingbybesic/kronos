// Kronos/MenuBar/MenuBarNextRows.swift
// NEXT — the next rows of the OPEN list under its current sort + filter. Computed with
// the exact same pipeline the list uses
// (`ListContext`, `Kronos/List/TaskListScreen.swift`) so the popover's order can never
// drift from what the window shows — this file only drops the first row (already shown
// as NOW above) and takes the next few.

import SwiftUI
import KronosCore

@MainActor
enum MenuBarNextRows {
    /// The next `count` open rows after the current focus, under `scope`'s live sort +
    /// filter. `excluding` lets the popover hide tasks already dismissed this session
    /// ("Not now") without writing anything to the store.
    static func rows(model: AppModel, scope: ListScope, focusTaskID: UUID?, excluding: Set<UUID>, count: Int = 5) -> [KTask] {
        let all = ListContext(model: model).rows
        return all
            .filter { $0.id != focusTaskID && !excluding.contains($0.id) }
            .prefix(count)
            .map { $0 }
    }
}

/// One row: project glyph + title, click = pin as focus. No checkbox (this is a queue
/// preview, not a place to complete from) and no drag handle outside Manual sort — the
/// brief allows omitting reorder-by-drag here in favour of shipping the rest of the
/// cockpit; the list window remains the place to reorder a Manual preset.
struct MenuBarNextRow: View {
    let task: KTask
    let onSelect: () -> Void
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: Space.x2) {
                KProjectGlyph(icon: task.project?.icon, colorHex: task.project?.colorHex, size: Metrics.iconM, carrier: .menuBarTitle)
                Text(task.title)
                    .font(Typo.row)
                    .foregroundStyle(Tok.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: Space.x2)
            }
            .padding(.horizontal, Space.x2)
            .frame(height: Metrics.rowHeightDense)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                .fill(isHovering ? Tok.hoverFill : .clear)
        )
        .kFocusRing(isFocused, radius: Radius.row)
        .focusable(true, interactions: .activate)
        .focused($isFocused)
        .focusEffectDisabled()
        .onHover { isHovering = $0 }
        .animation(Motion.hover, value: isHovering)
        .accessibilityLabel(task.project.map { "\(task.title), \($0.name)" } ?? task.title)
    }
}

/// The NEXT section: up to 5 rows behind the focus task, or nothing at all when that queue
/// is empty (a section with nothing to show stays silent rather than printing an
/// empty-state — this is a secondary list, not the screen's own empty state).
struct MenuBarNextSection: View {
    let rows: [KTask]
    let onSelect: (KTask) -> Void

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: Space.x1) {
                KHairline()
                Text(String(localized: "menubar.next.title"))
                    .font(Typo.caption)
                    .tracking(Tracking.caption)
                    .textCase(.uppercase)
                    .foregroundStyle(Tok.textTertiary)
                    .padding(.horizontal, Space.x2)
                    .padding(.top, Space.x1)
                    .fixedSize()
                ForEach(rows) { task in
                    MenuBarNextRow(task: task, onSelect: { onSelect(task) })
                }
            }
        }
    }
}
