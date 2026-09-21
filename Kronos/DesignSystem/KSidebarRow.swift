// Kronos/DesignSystem/KSidebarRow.swift
// Sidebar row: compact 28 pt rows, one small icon per row, the count on one shared trailing
// edge in tabular numerals, areas as a quiet disclosure. Selection uses a second channel — a
// WHITE leading bar drawn INSIDE the row (never colour, never fill alone). Project rows draw
// their mark through KProjectGlyph, so hue obeys the colour mode; in Calm the count also hides
// until the row is hovered.
// Both sidebar display modes via @Environment(\.kSidebarMode): iconsOnly renders a centred
// glyph with the name as tooltip + accessibility label.
//
// Geometry (every number a named Metrics.sidebar* token):
//   [row edge] leading 10 + indent*14 -> icon (16 box, fixed) -> gap 8 -> title … count -> trailing 10
// The icon column is a fixed-width frame so selection/hover never shifts it, and the
// selection bar sits inside the leading inset without pushing anything over.
// Usage: KSidebarRow(title: "Today", leadingIcon: "sun", count: 4, isSelected: sel) { select() }
//        KSidebarRow(title: "Acme", projectIcon: "utensils", colorHex: "#F2994A", isFocus: true, count: 3, indent: 1) { }
//        KSidebarRow(title: "Clients", isExpanded: open) { open.toggle() }
import SwiftUI

public struct KSidebarRow: View {
    public enum Leading {
        case icon(String)
        case dot(Color, size: CGFloat = Metrics.projectDot)
        case glyph(color: Color, emoji: String?, dotSize: CGFloat = Metrics.projectDot)
        case project(icon: String?, color: Color, isFocus: Bool)
        case disclosure(isExpanded: Bool)
        case none
    }

    let title: String
    var leading: Leading
    var count: Int?          // nil or 0 = nothing drawn (F: an empty scope stays silent)
    var indent: Int = 0
    var isSelected: Bool = false
    var isDropTarget: Bool = false
    var isArchived: Bool = false
    let onTap: () -> Void
    @Environment(\.kSidebarMode) private var mode
    @Environment(\.chromaMode) private var chromaMode
    @Environment(\.kAccent) private var accent
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    public init(title: String, leading: Leading, count: Int? = nil, indent: Int = 0, isSelected: Bool = false,
                isDropTarget: Bool = false, isArchived: Bool = false, onTap: @escaping () -> Void) {
        self.title = title
        self.leading = leading
        self.count = count
        self.indent = indent
        self.isSelected = isSelected
        self.isDropTarget = isDropTarget
        self.isArchived = isArchived
        self.onTap = onTap
    }

    public init(title: String, leadingIcon: String, count: Int? = nil, indent: Int = 0, isSelected: Bool = false, isDropTarget: Bool = false, isArchived: Bool = false, onTap: @escaping () -> Void) {
        self.init(title: title, leading: .icon(leadingIcon), count: count, indent: indent, isSelected: isSelected,
                  isDropTarget: isDropTarget, isArchived: isArchived, onTap: onTap)
    }

    public init(title: String, dot: Color, dotSize: CGFloat = Metrics.projectDot, count: Int? = nil, indent: Int = 0, isSelected: Bool = false, isDropTarget: Bool = false, isArchived: Bool = false, onTap: @escaping () -> Void) {
        self.init(title: title, leading: .dot(dot, size: dotSize), count: count, indent: indent, isSelected: isSelected,
                  isDropTarget: isDropTarget, isArchived: isArchived, onTap: onTap)
    }

    /// Legacy signature, kept for source compatibility: emoji is ignored, the mark is the
    /// project's dot.
    public init(title: String, glyphColor: Color, glyphEmoji: String? = nil, glyphDotSize: CGFloat = Metrics.projectDot, count: Int? = nil, indent: Int = 0, isSelected: Bool = false, isDropTarget: Bool = false, isArchived: Bool = false, onTap: @escaping () -> Void) {
        self.init(title: title, leading: .glyph(color: glyphColor, emoji: glyphEmoji, dotSize: glyphDotSize), count: count,
                  indent: indent, isSelected: isSelected, isDropTarget: isDropTarget, isArchived: isArchived, onTap: onTap)
    }

    /// A project: its own icon + colour. `isFocus` = the focus task belongs to this project.
    public init(title: String, projectIcon: String?, colorHex: String?, isFocus: Bool = false, count: Int? = nil, indent: Int = 0, isSelected: Bool = false, isDropTarget: Bool = false, isArchived: Bool = false, onTap: @escaping () -> Void) {
        let color = colorHex.map { Color(hexString: $0) } ?? Tok.textSecondary
        self.init(title: title, leading: .project(icon: projectIcon, color: color, isFocus: isFocus), count: count,
                  indent: indent, isSelected: isSelected, isDropTarget: isDropTarget, isArchived: isArchived, onTap: onTap)
    }

    /// An area: a quiet disclosure row (small chevron, no icon, no count).
    public init(title: String, isExpanded: Bool, indent: Int = 0, isSelected: Bool = false, isDropTarget: Bool = false, onTap: @escaping () -> Void) {
        self.init(title: title, leading: .disclosure(isExpanded: isExpanded), count: nil, indent: indent,
                  isSelected: isSelected, isDropTarget: isDropTarget, isArchived: false, onTap: onTap)
    }

    public var body: some View {
        Group {
            if mode == .iconsOnly, isDisclosure {
                // The rail has no hierarchy to disclose; the section hairline already separates it.
                EmptyView()
            } else if mode == .iconsOnly {
                railBody
            } else {
                fullBody
            }
        }
        .buttonStyle(.plain)
        // No focus ring on rows: `.focusable` takes focus on mouse click on macOS, so a ring
        // would outline every clicked row. Rows show SELECTION (fill + leading bar); the
        // owning screen moves selection with the arrow keys. Buttons and fields keep their ring.
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        // Activate-only: keyboard focus, never click focus. A plain focusable(true) made the
        // first mouse click take focus instead of pressing the row, so lists needed two or
        // three clicks before this fix.
        .focusable(true, interactions: .activate)
        .focused($isFocused)
        .focusEffectDisabled()
        .animation(Motion.hover, value: isHovering)
        .animation(Motion.select, value: isSelected)
        .animation(Motion.curve(Motion.medium), value: mode)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityCount)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .help(mode == .iconsOnly ? title : "")
        .uiTestAnchor("sidebar." + title)
    }

    private var accessibilityCount: String {
        guard let count else { return "" }
        return count == 0
            ? String(localized: "sidebar.row.count.none", defaultValue: "no tasks")
            : String(localized: "sidebar.row.count", defaultValue: "\(count) tasks")
    }

    private var isDisclosure: Bool {
        if case .disclosure = leading { return true }
        return false
    }

    private var titleTone: Color {
        if isArchived { return Tok.textDisabled }
        return isSelected || isHovering ? Tok.textPrimary : Tok.textSecondary
    }

    /// Calm hides counts until the row is hovered; the column keeps its width either way.
    private var countOpacity: Double { chromaMode == .calm && !isHovering ? 0 : 1 }

    // MARK: iconsAndText — full row
    private var fullBody: some View {
        Button(action: onTap) {
            HStack(spacing: 0) {
                // Selection bar occupies a fixed gutter INSIDE the leading inset so it
                // never pushes the icon column — the icon's x-position is identical
                // whether or not the row is selected.
                selectionBarGutter
                Color.clear.frame(width: Metrics.sidebarRowLeading - Metrics.sidebarSelectionBarWidth + CGFloat(indent) * Metrics.sidebarIndentStep)
                leadingView(size: Metrics.iconM)
                    .frame(width: Metrics.sidebarIconBox, alignment: .center)
                Color.clear.frame(width: Metrics.sidebarIconTextGap)
                Text(title)
                    .font(Typo.row)
                    .tracking(Tracking.row)
                    .foregroundStyle(titleTone)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: Metrics.sidebarIconTextGap)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(Typo.count)
                        .foregroundStyle(isSelected ? Tok.textSecondary : Tok.textTertiary)
                        .opacity(countOpacity)
                }
                Color.clear.frame(width: Metrics.sidebarRowTrailing)
            }
            .frame(height: Metrics.sidebarRowHeight)
            // The hit area belongs INSIDE the label: a .plain Button is only pressable on its
            // opaque pixels, and a contentShape outside it just makes a dead wrapper (missed
            // clicks 2-3x before this fix).
            .contentShape(Rectangle())
        }
        .background(rowFill)
        .overlay(rowEdge)
        .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
    }

    // MARK: iconsOnly — centred glyph rail
    private var railBody: some View {
        Button(action: onTap) {
            leadingView(size: Metrics.sidebarRailIconSize)
                .frame(maxWidth: .infinity)
                .frame(height: Metrics.sidebarRailRowHeight)
                .contentShape(Rectangle())
        }
        .background(rowFill)
        .overlay(rowEdge)
        .overlay(alignment: .leading) {
            if isSelected { selectionBar.padding(.leading, 2) }
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
    }

    @ViewBuilder
    private func leadingView(size: CGFloat) -> some View {
        switch leading {
        case .icon(let name):
            Icon(name, size: size)
                .foregroundStyle(isArchived ? Tok.textDisabled : (isSelected ? Tok.textPrimary : Tok.textTertiary))
        case .dot(let color, let dotSize):
            KProjectGlyph(icon: nil, color: color, size: size, dotSize: dotSize)
        case .glyph(let color, _, let dotSize):
            KProjectGlyph(icon: nil, color: color, size: size, dotSize: dotSize)
        case .project(let icon, let color, let isFocus):
            // Built here, at the row's own icon size, so the glyph always carries the
            // same visual weight as an Icon in the same column.
            KProjectGlyph(icon: icon, color: color, isFocus: isFocus, size: size, carrier: .sidebarProject)
                .opacity(isArchived ? 0.45 : 1)
        case .disclosure(let isExpanded):
            Icon("chevron-right", size: Metrics.sidebarDisclosure, weight: .semibold)
                .foregroundStyle(isHovering ? Tok.textSecondary : Tok.textTertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .animation(Motion.select, value: isExpanded)
        case .none:
            Color.clear.frame(width: size, height: size)
        }
    }

    private var rowFill: some View {
        RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
            .fill(isDropTarget ? Tok.dropFill : (isSelected ? Tok.selectedFill : (isHovering ? Tok.hoverFill : .clear)))
    }

    /// Selection's inner hairline, or the drop target's full outline.
    private var rowEdge: some View {
        RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
            .strokeBorder(isDropTarget ? Tok.textPrimary : (isSelected ? Tok.selectedEdge : Color.clear),
                          lineWidth: isDropTarget ? 1 : Metrics.strokeHair)
    }

    /// Fixed-width gutter so the bar's presence/absence never shifts the icon column.
    /// The bar is an overlay inside this always-present gutter, not a conditional
    /// child: a bare `Group { if cond { view } }` with no else collapses to zero
    /// width even under `.frame(width:)`, which was shifting the icon column on
    /// selection before this fix.
    private var selectionBarGutter: some View {
        Color.clear
            .frame(width: Metrics.sidebarSelectionBarWidth, height: Metrics.sidebarRowHeight - Metrics.sidebarSelectionBarInset * 2)
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.sidebarSelectionBarWidth / 2)
                    .fill(isSelected ? accent : Color.clear)
            )
    }

    private var selectionBar: some View {
        RoundedRectangle(cornerRadius: Metrics.sidebarSelectionBarWidth / 2)
            .fill(accent)
            .frame(width: Metrics.sidebarSelectionBarWidth,
                   height: Metrics.sidebarRailRowHeight - Metrics.sidebarSelectionBarInset * 2)
    }
}
