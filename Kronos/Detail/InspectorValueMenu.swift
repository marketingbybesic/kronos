// Kronos/Detail/InspectorValueMenu.swift
// A KPropertyRow value that opens a Menu but reads as plain left-aligned content: the
// same fix ListRowView's priorityMenu/effortMenu already use for the identical AppKit
// quirk (Menu's own `.menuStyle(.borderlessButton)` bakes an internal content inset
// into its label — `.padding` around the Menu only offsets the OUTER frame, not that
// inset, which is why `KMenuButton`'s value text still sat ~3.5pt right of a plain
// Text/TextField value even after cancelling KMenuButton's own outer padding). Fix:
// the Menu's own label is `Color.clear` (nothing for the button style to re-inset), and
// the real glyph + text is drawn as a non-hit-testing overlay, left-aligned at x=0 of a
// hit box sized to the content — so ink starts exactly where a plain Text would.
import SwiftUI

struct InspectorValueMenu<MenuItems: View, Leading: View>: View {
    let text: String
    /// An unset value reads dimmer than a chosen one (same as Repeat's "Never").
    var isUnset = false
    @ViewBuilder let items: () -> MenuItems
    @ViewBuilder let leading: () -> Leading
    @State private var isHovering = false

    init(text: String, isUnset: Bool = false, @ViewBuilder items: @escaping () -> MenuItems) where Leading == EmptyView {
        self.text = text
        self.isUnset = isUnset
        self.items = items
        self.leading = { EmptyView() }
    }

    init(text: String, @ViewBuilder leading: @escaping () -> Leading, @ViewBuilder items: @escaping () -> MenuItems) {
        self.text = text
        self.items = items
        self.leading = leading
    }

    var body: some View {
        // A real (non-clear) sibling with the same text/font, `.hidden()`, gives the
        // HStack its correct ideal width without measuring anything by hand — the
        // Menu's own `Color.clear` label never needs a size because the overlay draws
        // at the HStack's leading edge regardless; this sibling only exists so the
        // whole control's LAYOUT width (its hover-fill background, its hit area) matches
        // its visible content instead of collapsing to zero, mirroring `KMenuButton`'s
        // own `.fixedSize()` sizing without inheriting its content inset.
        HStack(spacing: Space.x1) {
            leading()
            Text(text).font(Typo.row)
            Icon("chevron-down", size: Metrics.iconXS)
        }
        .hidden()
        .frame(height: Metrics.controlCompact)
        .overlay {
            Menu { items() } label: { Color.clear }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
        }
        .overlay(alignment: .leading) {
            HStack(spacing: Space.x1) {
                leading()
                Text(text).font(Typo.row).foregroundStyle(isUnset ? Tok.textSecondary : Tok.textPrimary)
                Icon("chevron-down", size: Metrics.iconXS)
                    .foregroundStyle(Tok.textTertiary)
                    .opacity(isHovering ? 1 : 0)
            }
            .allowsHitTesting(false)
        }
        .background(
            RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                .fill(isHovering ? Tok.hoverFill : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(Motion.curve(Motion.fast), value: isHovering)
    }
}
