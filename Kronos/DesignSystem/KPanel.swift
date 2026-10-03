// Kronos/DesignSystem/KPanel.swift
// Bordered container — the OLED substitute for a grey card: pure black (inline and floating
// alike), elevation carried by the `Tok.borderControl` edge only. Usage:
//   KPanel { VStack { ... } }
import SwiftUI

public struct KPanel<Content: View>: View {
    var padding: CGFloat
    var radius: CGFloat
    var floating: Bool
    @ViewBuilder let content: () -> Content

    /// - Parameter floating: true for overlays/popovers that lift off the window (uses
    ///   `Tok.overlay`). Both `Tok.overlay` and `Tok.bg` are pure black (OLED, no grey
    ///   panels); the separate token keeps the floating role named in one place.
    public init(padding: CGFloat = Metrics.panelPadding, radius: CGFloat = Radius.card,
                floating: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.padding = padding
        self.radius = radius
        self.floating = floating
        self.content = content
    }

    public var body: some View {
        content()
            .padding(padding)
            .background(floating ? Tok.overlay : Tok.bg)
            .kBorder(Tok.borderControl, radius: radius)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}
