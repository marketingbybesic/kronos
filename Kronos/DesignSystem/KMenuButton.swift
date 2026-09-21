// Kronos/DesignSystem/KMenuButton.swift
// Borderless button that opens a Menu, styled like the inspector's popover buttons:
// glyph -> value -> chevron, chevron hover-revealed at textTertiary.
// Usage:
//   KMenuButton(text: "Priority") { Button("High") { } ... } leading: { Icon("flag") }
//   KMenuButton(text: "Save view") { Button("Save") { } ... }   // no leading glyph
//
// IMPORTANT macOS `Menu` quirks (all four confirmed by direct repro):
// 1. `Menu`'s own `label:` closure silently drops any Shape-drawn content (a Circle/
//    RoundedRectangle-based glyph like KPriorityIndicator renders as nothing —
//    `.drawingGroup()` does not fix it). Image/SF Symbol-backed content (Icon,
//    Image(systemName:)) renders fine inside a Menu label.
// 2. `Menu` always draws its own chevron unless `.menuIndicator(.hidden)` is set.
// 3. Even with `.menuIndicator(.hidden)` set, a manual chevron placed INSIDE the
//    Menu's own `label:` HStack gets visually reordered to before the label text by
//    `.menuStyle(.borderlessButton)`'s internal layout — glyph/chevron/text instead of
//    the HStack's own written order glyph/text/chevron. Confirmed: the same chevron
//    placed OUTSIDE the Menu (in this view's own trailing position, sibling to the
//    Menu rather than inside its label) keeps the written order. So `leading` AND the
//    hover chevron both live outside the Menu; only the plain value text is the
//    Menu's own label content.
// 4. A `Menu` that becomes on-screen right after a sibling `TextField`/`KTextField` had first
//    responder — e.g. this button replaces that text field
//    in the same view swap, not just sits near it — silently eats its FIRST click: AppKit
//    leaves the text field's field-editor `NSTextView` as the window's first responder across
//    the swap (confirmed with a standalone `NSHostingView` repro: still the first responder
//    both in the same tick as the swap AND on the next run-loop turn — nothing here ever
//    resigns it), so that first click is consumed resigning the stale responder instead of
//    opening the menu; a second click, with nothing stale left, works. This `Menu` did not
//    cause that and cannot fix it alone — the caller that swaps a text field for a `KMenuButton`
//    must call `NSApp.keyWindow?.makeFirstResponder(nil)` at the moment of the swap (see
//    `Kronos/Triage/TriageFlowView.swift`'s `.onChange(of: isEditingDate)` for the fixed case).
import SwiftUI

public struct KMenuButton<MenuItems: View, Leading: View>: View {
    @ViewBuilder let leading: () -> Leading
    let text: String
    @ViewBuilder let items: () -> MenuItems
    @State private var isHovering = false

    public init(text: String, @ViewBuilder items: @escaping () -> MenuItems) where Leading == EmptyView {
        self.leading = { EmptyView() }
        self.text = text
        self.items = items
    }

    public init(text: String, @ViewBuilder items: @escaping () -> MenuItems, @ViewBuilder leading: @escaping () -> Leading) {
        self.leading = leading
        self.text = text
        self.items = items
    }

    public var body: some View {
        HStack(spacing: Space.x1) {
            leading()
            Menu {
                items()
            } label: {
                Text(text)
                    .font(Typo.row)
                    .foregroundStyle(Tok.textPrimary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Icon("chevron-down", size: Metrics.iconXS)
                .foregroundStyle(Tok.textTertiary)
                .opacity(isHovering ? 1 : 0)
        }
        .padding(.horizontal, Space.x2)
        .frame(height: Metrics.controlCompact)
        .background(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(isHovering ? Tok.hoverFill : .clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(Motion.curve(Motion.fast), value: isHovering)
    }
}
