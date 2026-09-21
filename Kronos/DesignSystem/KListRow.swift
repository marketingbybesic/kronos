// Kronos/DesignSystem/KListRow.swift
// Task-row scaffold: leading checkbox, title, trailing metadata slots. Screens compose
// their own row content from this + KBadge/KChip/PriorityGlyph-style views; this owns
// only the shared shell (height, selection bar, hover, focus).
// Usage:
//   KListRow(isSelected: sel, isChecked: done, onToggle: { }, onSelect: { }) {
//       Text(task.title).font(Typo.row).foregroundStyle(Tok.textPrimary)
//   } trailing: {
//       KBadge("2")
//   }
// Pass `accessibilityLabel` with the full composed string (e.g. "High priority, todo,
// due today, Acme, 2 of 5 subtasks") — spec §13.2 requires a TaskRow to be ONE
// accessibility element, not a pile of child elements, so a 200-row list stays usable
// with VoiceOver. Leave it nil only for a scaffold that isn't a real task row yet.
//
// Geometry (spec B3, mirrors the sidebar's rhythm): row height 36, leading inset 12 to
// the checkbox (16pt, style G), gap 10 to the title, trailing metadata right-aligned with a
// 12pt trailing inset and 8pt between slots. The selected row's bar uses the same
// geometry as KSidebarRow's (white, 2pt, inset 6 top/bottom).
import SwiftUI

public struct KListRow<Title: View, Trailing: View>: View {
    var isSelected: Bool = false
    var isMultiSelected: Bool = false
    var isDone: Bool = false
    var density: CGFloat = Metrics.rowHeight
    let isChecked: Bool
    var accessibilityLabel: String?
    let onToggle: () -> Void
    let onSelect: () -> Void
    @ViewBuilder let title: () -> Title
    @ViewBuilder var trailing: () -> Trailing
    @State private var isHovering = false
    @FocusState private var isFocused: Bool
    @Environment(\.kAccent) private var accent

    public init(isSelected: Bool = false, isMultiSelected: Bool = false, isDone: Bool = false,
                density: CGFloat = Metrics.rowHeight, isChecked: Bool, accessibilityLabel: String? = nil,
                onToggle: @escaping () -> Void, onSelect: @escaping () -> Void,
                @ViewBuilder title: @escaping () -> Title,
                @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.isSelected = isSelected
        self.isMultiSelected = isMultiSelected
        self.isDone = isDone
        self.density = density
        self.isChecked = isChecked
        self.accessibilityLabel = accessibilityLabel
        self.onToggle = onToggle
        self.onSelect = onSelect
        self.title = title
        self.trailing = trailing
    }

    private var isEmphasized: Bool { isSelected || isMultiSelected }

    public var body: some View {
        rowContent
            .padding(.horizontal, 6)
            // No focus ring on rows: `.focusable` takes focus on mouse click on macOS, so a
            // ring would outline every clicked row. Rows show SELECTION (fill + leading bar);
            // the owning screen moves selection with the arrow keys. Buttons and fields keep
            // their ring.
            .onHover { isHovering = $0 }
            .focusable(true, interactions: .activate)
            .focused($isFocused)
            .focusEffectDisabled()
            .environment(\.kRowHovered, isHovering)
            .animation(Motion.hover, value: isHovering)
            .animation(Motion.select, value: isSelected)
            // Folds the row into ONE accessibility element (spec §13.2) so a 200-row
            // list stays usable with VoiceOver instead of exposing a checkbox/title/
            // trailing pile per row. An empty label when uncomposed is harmless.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel ?? "")
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(isDone ? String(localized: "status.done") : "")
    }

    private var rowContent: some View {
        HStack(spacing: 0) {
            selectionBarGutter
            Color.clear.frame(width: Metrics.listRowLeading - Metrics.sidebarSelectionBarWidth)
            KCheckbox(isChecked: isChecked, size: Metrics.listCheckboxSize, onToggle: onToggle)
            Color.clear.frame(width: Metrics.listCheckboxTitleGap)
            titleContent
            Spacer(minLength: Metrics.listCheckboxTitleGap)
            trailingContent
            Color.clear.frame(width: Metrics.listRowTrailing)
        }
        .frame(height: density)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .background(rowFill)
        .overlay(rowEdge)
        .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
    }

    private var titleContent: some View {
        title().opacity(isDone ? 0.6 : 1)
    }

    private var trailingContent: some View {
        HStack(spacing: Metrics.listTrailingSlotGap) {
            trailing()
        }
    }

    /// Selection's 0.5 pt inner hairline: depth on pure black without a grey slab.
    private var rowEdge: some View {
        RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
            .strokeBorder(isEmphasized ? Tok.selectedEdge : Color.clear, lineWidth: Metrics.strokeHair)
    }

    private var rowFill: some View {
        RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
            .fill(isEmphasized ? Tok.selectedFill : (isHovering ? Tok.hoverFill : .clear))
    }

    /// Fixed-width gutter so the bar's presence/absence never shifts the checkbox
    /// column — matches KSidebarRow's selection geometry. The bar is an OVERLAY inside
    /// this always-present gutter, not a conditional child of the HStack: a bare
    /// `Group { if cond { view } }` with no else collapses to zero width even under
    /// `.frame(width:)` (measured regression — selected rows shifted checkbox/title
    /// ~14pt right of unselected rows before this fix), so the gutter itself must
    /// always exist and only its fill toggles.
    private var selectionBarGutter: some View {
        Color.clear
            .frame(width: Metrics.sidebarSelectionBarWidth, height: density - Metrics.sidebarSelectionBarInset * 2)
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.sidebarSelectionBarWidth / 2)
                    .fill(isEmphasized ? accent : Color.clear)
            )
    }
}
