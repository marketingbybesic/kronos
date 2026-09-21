// Kronos/DesignSystem/KEffortIndicator.swift
// Glanceable effort glyph: a dot bar, monochrome, filled up to `level` of `steps`. Data-
// agnostic — no enum, so it never collides with KronosCore's own KEffort. The caller
// maps its real enum's rawValue to `level`.
// Usage: KEffortIndicator(level: 3, of: 5, label: "M")
import SwiftUI

public struct KEffortIndicator: View {
    let level: Int      // 0 = none/empty
    let steps: Int      // total dots, e.g. 5
    let label: String?
    var showLabel: Bool

    public init(level: Int, of steps: Int = 5, label: String? = nil, showLabel: Bool = true) {
        self.level = level
        self.steps = max(steps, 1)
        self.label = label
        self.showLabel = showLabel
    }

    public var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                ForEach(0..<steps, id: \.self) { i in
                    Circle()
                        .fill(i < level ? Tok.textSecondary : Tok.glyphEmpty)
                        .frame(width: 4, height: 4)
                }
            }
            if showLabel, let label, level > 0 {
                Text(label)
                    .font(Typo.count)
                    .foregroundStyle(Tok.textTertiary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "viewoptions.field.effort"))
        .accessibilityValue(label ?? "")
    }
}
