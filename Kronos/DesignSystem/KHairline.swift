// Kronos/DesignSystem/KHairline.swift
// Divider — decorative only, never a control's sole boundary. Usage: KHairline()
import SwiftUI

public struct KHairline: View {
    var vertical: Bool
    public init(vertical: Bool = false) { self.vertical = vertical }

    public var body: some View {
        Rectangle()
            .fill(Tok.hairline)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
            .accessibilityHidden(true)
    }
}
