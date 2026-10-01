// Kronos/DesignSystem/KBulkBar.swift
// Floating action bar for a multi-selection: "N selected" + whatever controls the caller
// passes + a close button. Pure #000 with a hairline border, never a coloured chip. It is
// only mounted while 2+ rows are selected (the caller decides), so it adds nothing to the
// resting layout. Slides up from the bottom edge; Reduce Motion swaps that for a fade.
// Usage:
//   if count > 1 { KBulkBar(label: "3 selected", closeLabel: "Clear selection", onClose: { }) { ...controls } }
import SwiftUI

public struct KBulkBar<Controls: View, Trailing: View>: View {
    let label: String
    let closeLabel: String
    let onClose: () -> Void
    @ViewBuilder let controls: () -> Controls
    /// Destructive action(s), set apart from the rest by a hairline and always last (audit D14).
    let trailing: (() -> Trailing)?
    @State private var closeHover = false

    public init(label: String, closeLabel: String, onClose: @escaping () -> Void,
                @ViewBuilder controls: @escaping () -> Controls,
                @ViewBuilder trailing: @escaping () -> Trailing) {
        self.init(label: label, closeLabel: closeLabel, onClose: onClose, controls: controls, optionalTrailing: trailing)
    }

    fileprivate init(label: String, closeLabel: String, onClose: @escaping () -> Void,
                     @ViewBuilder controls: @escaping () -> Controls,
                     optionalTrailing trailing: (() -> Trailing)?) {
        self.label = label
        self.closeLabel = closeLabel
        self.onClose = onClose
        self.controls = controls
        self.trailing = trailing
    }

    public var body: some View {
        HStack(spacing: Space.x3) {
            Text(label)
                .font(Typo.metaStrong)
                .foregroundStyle(Tok.textPrimary)
                .padding(.horizontal, Space.x2)
                .fixedSize()
            KHairline(vertical: true)
                .frame(height: Metrics.iconM)
            HStack(spacing: Space.x3) { controls() }
            if let trailing {
                KHairline(vertical: true)
                    .frame(height: Metrics.iconM)
                trailing()
            }
            Button(action: onClose) {
                Icon("x", size: Metrics.iconXS)
                    .foregroundStyle(closeHover ? Tok.textPrimary : Tok.textTertiary)
                    .frame(width: Metrics.controlCompact, height: Metrics.controlCompact)
                    .contentShape(Rectangle())   // inside the label: the glyph alone is a tiny target
            }
            .buttonStyle(.plain)
            .onHover { closeHover = $0 }
            .accessibilityLabel(closeLabel)
        }
        .padding(.horizontal, Space.x2)
        .frame(height: Metrics.controlRegular + Space.x2)
        .background(Tok.bg)
        .kBorder(Tok.hairline, radius: Radius.card)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .transition(Motion.reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .contain)
    }
}

extension KBulkBar where Trailing == EmptyView {
    public init(label: String, closeLabel: String, onClose: @escaping () -> Void,
                @ViewBuilder controls: @escaping () -> Controls) {
        self.init(label: label, closeLabel: closeLabel, onClose: onClose, controls: controls, optionalTrailing: nil)
    }
}
