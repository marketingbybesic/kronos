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
        Button(action: onTap) {
            HStack(spacing: Space.x1) {
                leading()
                Text(text)
                    .font(Typo.meta)
                    .foregroundStyle(isHovering ? Tok.textPrimary : Tok.textSecondary)
                    .lineLimit(1)
                switch trailing {
                case .none: EmptyView()
                case .chevron:
                    Icon("chevron-down", size: Metrics.iconXS).foregroundStyle(Tok.textTertiary)
                case .clear:
                    Button(action: { (onTrailingTap ?? onTap)() }) {
                        Icon("x", size: Metrics.iconXS)
                            .foregroundStyle(isHovering ? Tok.textPrimary : Tok.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .frame(minWidth: Metrics.minHit, minHeight: Metrics.minHit)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Space.x2)
        .frame(height: 24)
        .background(isHovering ? Tok.hoverFill : Tok.raised)
        .kBorder(isHovering ? Tok.borderStrong : Tok.borderControl, radius: Radius.chip)
        .clipShape(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
        .kFocusRing(isFocused, radius: Radius.chip)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .focusable(true, interactions: .activate)
        .focused($isFocused)
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
