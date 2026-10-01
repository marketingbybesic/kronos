// Kronos/DesignSystem/KChip.swift
// Filter/sort chip with an optional leading glyph slot and optional trailing chevron
// (menu) or clear (✕). Usage:
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
    @ViewBuilder let leading: () -> Leading
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    public init(_ text: String, trailing: Trailing = .none, onTap: @escaping () -> Void = {},
                onTrailingTap: (() -> Void)? = nil, @ViewBuilder leading: @escaping () -> Leading) {
        self.text = text
        self.trailing = trailing
        self.onTap = onTap
        self.onTrailingTap = onTrailingTap
        self.leading = leading
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
                .frame(height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(true, interactions: .activate)
            .focused($isFocused)
            .accessibilityLabel(text)
            .accessibilityAddTraits(.isButton)
            if trailing == .clear {
                Button(action: { (onTrailingTap ?? onTap)() }) {
                    Icon("x", size: Metrics.iconXS)
                        .foregroundStyle(isHovering ? Tok.textPrimary : Tok.textTertiary)
                        .frame(width: Metrics.minHit, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
        self.init(text, trailing: trailing, onTap: onTap, onTrailingTap: onTrailingTap) { EmptyView() }
    }
}
