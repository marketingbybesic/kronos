// Kronos/DesignSystem/KDeadlineLabel.swift
// Relative deadline text. Overdue is shown calmly with a neutral "Nd" carry pill —
// never red, never bold alarm — matching the app's no-alarm-colour rule (spec §5.5, D13).
// Usage: KDeadlineLabel(text: "Today", carryDays: 3)
import SwiftUI

public struct KDeadlineLabel: View {
    let text: String          // pre-formatted by the caller (locale/relative-date logic lives outside DesignSystem)
    var carryDays: Int?       // > 0 shows the carry pill
    var isDone: Bool

    public init(text: String, carryDays: Int? = nil, isDone: Bool = false) {
        self.text = text
        self.carryDays = carryDays
        self.isDone = isDone
    }

    public var body: some View {
        HStack(spacing: Space.x1) {
            Text(text)
                .font(Typo.count)
                .foregroundStyle(Tok.textSecondary)
                .lineLimit(1)
                .fixedSize()
            if let carryDays, carryDays > 0 {
                Text("\(carryDays)d")
                    .font(Typo.count)
                    .foregroundStyle(Tok.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, Space.x1 + 2)
                    .frame(height: 16)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
                    .kBorder(Tok.hairline, radius: Radius.chip)
                    // GAP (reported): deadline.carried.accessibility ("Carried over") has
                    // no day count — appending the number rather than dropping it or
                    // inventing a pluralized translation.
                    .accessibilityLabel("\(String(localized: "deadline.carried.accessibility")) \(carryDays)")
            }
        }
        .opacity(isDone ? 0.6 : 1)
        .accessibilityElement(children: .combine)
    }
}
