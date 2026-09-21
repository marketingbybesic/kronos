// Kronos/DesignSystem/KBadge.swift
// Count pill / small status badge. Monochrome by default — `tint` exists only for a
// caller passing user DATA colour (e.g. a project's own colour); chrome badges (counts,
// carry pills) always use the default Tok.textTertiary/textSecondary tones.
// Usage: KBadge("3"), KBadge("2d", tint: Tok.textSecondary)
import SwiftUI

public struct KBadge: View {
    let text: String
    var tint: Color
    var isSubtle: Bool

    public init(_ text: String, tint: Color = Tok.textTertiary, isSubtle: Bool = true) {
        self.text = text
        self.tint = tint
        self.isSubtle = isSubtle
    }

    public var body: some View {
        Text(text)
            .font(Typo.count)
            .foregroundStyle(tint)
            .padding(.horizontal, Space.x2)
            .frame(height: 18)
            .background(
                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                    .fill(isSubtle ? tint.opacity(0.14) : tint)
            )
    }
}
