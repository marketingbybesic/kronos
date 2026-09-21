// Kronos/DesignSystem/KPriorityIndicator.swift
// Monochrome priority glyph — a 4-bar signal, shape only, never colour, never an
// exclamation mark (that reads as a pressure/alarm signal, which is banned everywhere
// in this app). Data-agnostic: takes a raw level so the design system never declares a
// type that could collide with KronosCore's own KPriority. The caller (a UI leaf that
// does import KronosCore) maps its real enum's rawValue to `level`.
// Usage: KPriorityIndicator(level: 4, of: 4, label: "Urgent")   // all 4 bars filled
import SwiftUI

public struct KPriorityIndicator: View {
    let level: Int          // 0 = none/empty, up to `steps`
    let steps: Int          // total bars, 4: none/low/medium/high/urgent = 0/1/2/3/4
    let label: String?
    var size: CGFloat

    public init(level: Int, of steps: Int = 4, label: String? = nil, size: CGFloat = 14) {
        self.level = level
        self.steps = max(steps, 1)
        self.label = label
        self.size = size
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<steps, id: \.self) { i in
                bar(index: i, filled: i < level)
            }
        }
        // The frame is as wide as the bars really are (4 x 3 + 3 x 2 = 18 > 14): a narrower frame
        // let the bars overflow into a neighbouring label (quick add chip, caught on the read).
        .frame(width: max(size, CGFloat(steps) * 3 + CGFloat(steps - 1) * 2), height: size, alignment: .bottom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "viewoptions.field.priority"))
        .accessibilityValue(label ?? "")
    }

    /// Bars step up in height left to right regardless of `steps` count, so a 4-bar and
    /// a 3-bar glyph both read as an ascending signal rather than a flat row.
    private func bar(index: Int, filled: Bool) -> some View {
        let minHeight: CGFloat = size * 0.36
        let maxHeight: CGFloat = size * 0.86
        let step = steps > 1 ? (maxHeight - minHeight) / CGFloat(steps - 1) : 0
        let height = minHeight + step * CGFloat(index)
        return RoundedRectangle(cornerRadius: 1)
            .fill(filled ? Tok.textSecondary : Tok.glyphEmpty)
            .frame(width: 3, height: height)
    }
}
