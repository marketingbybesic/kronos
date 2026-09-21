// Kronos/DesignSystem/KPanel.swift
// Bordered container — the OLED substitute for a grey card. Usage:
//   KPanel { VStack { ... } }
import SwiftUI

public struct KPanel<Content: View>: View {
    var padding: CGFloat
    var radius: CGFloat
    @ViewBuilder let content: () -> Content

    public init(padding: CGFloat = Metrics.panelPadding, radius: CGFloat = Radius.card, @ViewBuilder content: @escaping () -> Content) {
        self.padding = padding
        self.radius = radius
        self.content = content
    }

    public var body: some View {
        content()
            .padding(padding)
            .background(Tok.bg)   // style G: a hairline carries the panel, never a grey fill
            .kBorder(Tok.borderControl, radius: radius)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}
