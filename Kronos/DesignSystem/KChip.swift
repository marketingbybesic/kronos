// Kronos/DesignSystem/KChip.swift
// The INTERACTIVE pill: it does something on click (opens a menu, removes a rule, edits a slot).
// 24 pt (`Metrics.chipHeight`, its own hit target), `Radius.chip`, hairline border, the ✕
// inside the border. A pill that only shows a value is a KTag. The app has exactly these two
// pill shapes; the capsule is reserved for the undo pill.
// Optional leading glyph slot and optional trailing chevron (menu) or clear (✕). Usage:
//   KChip("Status is Todo", trailing: .clear) { onRemove() }
//   KChip("Priority", trailing: .chevron) { openMenu() }
//   KChip("Acme", leading: { KProjectGlyph(color: .orange, emoji: "🌵", size: Metrics.iconS) })
import SwiftUI

public struct KChip<Leading: View>: View {
    public enum Trailing { case none, chevron, clear }

    let text: String
    var trailing: Trailing
    let onTap: () -> Void
    var onTrailingTap: (() -> Void)?
    /// Live-UI-test anchor of the ✕ button (nil outside a test run's needs).
    var trailingAnchorID: String?
    @ViewBuilder let leading: () -> Leading
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    public init(_ text: String, trailing: Trailing = .none, onTap: @escaping () -> Void = {},
                onTrailingTap: (() -> Void)? = nil, trailingAnchorID: String? = nil,
                @ViewBuilder leading: @escaping () -> Leading) {
        self.text = text
        self.trailing = trailing
        self.onTap = onTap
        self.onTrailingTap = onTrailingTap
        self.trailingAnchorID = trailingAnchorID
        self.leading = leading
    }

    @ViewBuilder private func anchored<V: View>(_ v: V) -> some View {
        if let id = trailingAnchorID { v.uiTestAnchor(id) } else { v }
    }

    public var body: some View {
        // Two SIBLING buttons for a removable chip, never a Button inside a Button: SwiftUI
        // flattens the inner one away, so VoiceOver (and AXPress) could not reach the remove
        // control at all.
        HStack(spacing: 0) {
            Button(action: onTap) {
                HStack(spacing: Space.x1) {
                    leading()
                    Text(text)
                        .font(Typo.meta)
                        .foregroundStyle(isHovering ? Tok.textPrimary : Tok.textSecondary)
                        .lineLimit(1)
                    if trailing == .chevron {
                        Icon("chevron-down", size: Metrics.iconXS).foregroundStyle(Tok.textTertiary)
                    }
                }
                // Padding, height and hit shape INSIDE the label: a plain-style button is
                // pressable only on its label's pixels, so with these outside only the
                // text/glyph took a click.
                .padding(.leading, Space.x2)
                .padding(.trailing, trailing == .clear ? Space.x1 : Space.x2)
                .frame(height: Metrics.chipHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(true, interactions: .activate)
            .focused($isFocused)
            .accessibilityLabel(text)
            .accessibilityAddTraits(.isButton)
            if trailing == .clear {
                anchored(Button(action: { (onTrailingTap ?? onTap)() }) {
                    Icon("x", size: Metrics.iconXS)
                        .foregroundStyle(isHovering ? Tok.textPrimary : Tok.textTertiary)
                        .frame(width: Metrics.minHit, height: Metrics.chipHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain))
                .padding(.trailing, Space.x2)
                .accessibilityLabel(String(format: String(localized: "a11y.chip.remove"), text))
                .accessibilityAddTraits(.isButton)
            }
        }
        .background(isHovering ? Tok.hoverFill : Tok.raised)
        .kBorder(isHovering ? Tok.borderStrong : Tok.borderControl, radius: Radius.chip)
        .clipShape(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
        .kFocusRing(isFocused, radius: Radius.chip)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(Motion.hover, value: isHovering)
    }
}

public extension KChip where Leading == EmptyView {
    /// Source-compatible with every call site written before the leading-glyph slot
    /// existed: `KChip("text", trailing: .clear) { onRemove() }` still resolves here.
    init(_ text: String, trailing: Trailing = .none, onTap: @escaping () -> Void = {},
         onTrailingTap: (() -> Void)? = nil) {
        self.init(text, trailing: trailing, onTap: onTap, onTrailingTap: onTrailingTap, trailingAnchorID: nil) { EmptyView() }
    }
}
