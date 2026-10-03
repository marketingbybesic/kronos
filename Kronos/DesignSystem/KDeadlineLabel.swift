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
                // A passive value, so the shared passive pill (KTag), not a bespoke plate.
                KTag("\(carryDays)d", tone: Tok.textSecondary)
                    // GAP (reported): deadline.carried.accessibility ("Carried over") has
                    // no day count — appending the number rather than dropping it or
                    // inventing a pluralized translation.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(String(localized: "deadline.carried.accessibility")) \(carryDays)")
            }
        }
        .opacity(isDone ? 0.6 : 1)
        .accessibilityElement(children: .combine)
    }
}
