// Kronos/DesignSystem/KTag.swift
// The PASSIVE pill: shows a value inside a row (a carry count "3d", a label, "1/5") and does
// nothing on click. 16 pt (`Metrics.tagHeight`), `Radius.chip`, a faint `Tok.tagFill` plate, no
// border, no hover. Anything clickable is a KChip instead; the app has exactly these two pill
// shapes. A tag is usually already part of its row's composed VoiceOver label, so a caller that
// repeats the value there hides the tag (`.accessibilityHidden(true)`).
// Usage: KTag("3d", tone: Tok.textSecondary)
//        KTag("Waiting", dot: projectColor)
import SwiftUI

public struct KTag: View {
    let text: String
    var tone: Color
    var dot: Color?
    var font: Font

    public init(_ text: String, tone: Color = Tok.textTertiary, dot: Color? = nil, font: Font = Typo.count) {
        self.text = text
        self.tone = tone
        self.dot = dot
        self.font = font
    }

    public var body: some View {
        HStack(spacing: Space.x1) {
            if let dot {
                Circle().fill(dot)
                    .frame(width: Metrics.projectDot, height: Metrics.projectDot)
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(font)
                .foregroundStyle(tone)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, Space.x1 + Space.x1 / 2)
        .frame(height: Metrics.tagHeight)
        .background(
            RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                .fill(Tok.tagFill)
        )
    }
}
