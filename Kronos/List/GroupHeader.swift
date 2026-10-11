// Kronos/List/GroupHeader.swift
// Generic sticky section header for a grouped list (spec §4.6): a disclosure chevron, the
// group's title (+ an optional separate count badge), and up to two trailing slots — the
// spec's hover-revealed "+" (creates a task pre-set to this group's value) and a caller-
// supplied trailing content block for anything richer. Used as a `Section`'s `header:` inside
// a `LazyVStack(pinnedViews: [.sectionHeaders])` so it actually sticks to the top of the
// scroll view while its group is on screen (TaskListScreen.swift).
//
// `title`/`count` are two slots (spec: "Status" + "12") OR one caller can pass an already
// composed sentence as `title` with `count: nil` — ListMissingHeader ("No deadline (3)") and
// ListEarlierHeader ("Earlier (12)") both do this, since their localized copy already embeds
// the count as a single translated sentence; splitting that sentence into a bare field name
// plus a separately-styled number would change existing, already-translated strings for no
// visible gain. `anchor` lets a caller keep an existing `.uiTestAnchor`/click target (the two
// upgrades below preserve "today.earlier.header" / "list.missing.header" exactly, since the
// live UI test clicks them by name) instead of the derived `"group.header." + title` default.
//
// Background: `Tok.bg` at 0.92 opacity + `.ultraThinMaterial` so rows scrolling underneath
// stay legible through the sticky bar; Reduce Transparency drops the material for an opaque
// `Tok.bg` fill (KTransparency, spec §12). Apple-design-audit finding: the opaque RT fill has
// no edge of its own, so a row scrolling under the sticky bar is indistinguishable from one
// still inside it — a bottom `KHairline` closes that gap, RT-only, default rendering untouched.
import SwiftUI

struct GroupHeader<Trailing: View>: View {
    let title: String
    var leading: KSidebarRow.Leading = .none
    var count: Int?
    let isCollapsed: Bool
    let onToggle: () -> Void
    var onAdd: (() -> Void)?
    var anchor: String?
    @ViewBuilder var trailing: () -> Trailing
    @State private var isHovering = false

    private var resolvedAnchor: String { anchor ?? "group.header." + title }

    var body: some View {
        HStack(spacing: Space.x2) {
            disclosure
            Spacer(minLength: Space.x2)
            trailing()
            addButton
        }
        .padding(.horizontal, Space.x3)
        .frame(height: Metrics.groupHeaderHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .overlay(alignment: .bottom) {
            // RT-only: the opaque `Tok.bg` fill (unlike `.ultraThinMaterial`) has no visual
            // edge against rows scrolling underneath, so this hairline restores that separation.
            if KTransparency.isReduced { KHairline() }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(Motion.curve(Motion.fast), value: isHovering)
    }

    private var disclosure: some View {
        Button(action: onToggle) {
            HStack(spacing: Space.x1) {
                Icon("chevron-right", size: Metrics.iconXS)
                    .foregroundStyle(Tok.textTertiary)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .animation(Motion.select, value: isCollapsed)
                    .accessibilityHidden(true)
                leadingMark
                Text(title)
                    .font(Typo.sectionHdr)
                    .textCase(.uppercase)
                    .foregroundStyle(Tok.textSecondary)
                if let count {
                    Text("\(count)")
                        .font(Typo.meta)
                        .foregroundStyle(Tok.textTertiary)
                }
            }
            .frame(minHeight: Metrics.minHit)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isCollapsed ? String(localized: "today.earlier.a11y.closed")
                                         : String(localized: "today.earlier.a11y.open"))
        .uiTestAnchor(resolvedAnchor)
    }

    @ViewBuilder private var leadingMark: some View {
        switch leading {
        case .icon(let name):
            Icon(name, size: Metrics.iconXS).foregroundStyle(Tok.textTertiary)
        case .dot(let color, let size):
            Circle().fill(color).frame(width: size, height: size)
        case .glyph(let color, _, let dotSize):
            Circle().fill(color).frame(width: dotSize, height: dotSize)
        case .project, .disclosure, .none:
            EmptyView()
        }
    }

    @ViewBuilder private var addButton: some View {
        if let onAdd {
            Button(action: onAdd) {
                Icon("plus", size: Metrics.iconXS).foregroundStyle(Tok.textTertiary)
            }
            .buttonStyle(.plain)
            .frame(minWidth: Metrics.minHit, minHeight: Metrics.minHit)
            .opacity(isHovering ? 1 : 0)
            // Always present in the accessibility tree regardless of visual opacity, like
            // KSectionHeader's own hover-revealed trailing action.
            .accessibilityHidden(false)
            .accessibilityLabel(String(localized: "common.add"))
            .uiTestAnchor(resolvedAnchor + ".add")
        }
    }

    @ViewBuilder private var background: some View {
        if KTransparency.isReduced {
            Tok.bg
        } else {
            Tok.bgTranslucent.background(.ultraThinMaterial)
        }
    }
}

extension GroupHeader where Trailing == EmptyView {
    init(title: String, leading: KSidebarRow.Leading = .none, count: Int? = nil, isCollapsed: Bool,
         onToggle: @escaping () -> Void, onAdd: (() -> Void)? = nil, anchor: String? = nil) {
        self.init(title: title, leading: leading, count: count, isCollapsed: isCollapsed, onToggle: onToggle,
                  onAdd: onAdd, anchor: anchor, trailing: { EmptyView() })
    }
}
