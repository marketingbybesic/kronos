// Kronos/DesignSystem/KPropertyRow.swift
// Style G's borderless property list row (the inspector stops being a form): a fixed,
// tertiary label column and the value next to it, a full-row hover fill, no box. The
// value is any view — plain text, an indicator, a KAttributeMenu — so the control
// "appears on click" by being the value itself. Stack rows with spacing 0; separate
// groups with KHairline.
// Usage: KPropertyRow("Deadline") { KDeadlineLabel(text: "15 Sep", carryDays: 4) }
//        KPropertyRow("Status", value: "To do")
import SwiftUI

public struct KPropertyRow<Value: View>: View {
    let label: String
    var labelWidth: CGFloat
    @ViewBuilder let value: () -> Value
    @State private var isHovering = false

    public init(_ label: String, labelWidth: CGFloat = Metrics.propertyLabelColumn, @ViewBuilder value: @escaping () -> Value) {
        self.label = label
        self.labelWidth = labelWidth
        self.value = value
    }

    public var body: some View {
        HStack(spacing: 0) {
            Text(label)
                .font(Typo.row)
                .foregroundStyle(Tok.textTertiary)
                .lineLimit(1)
                .frame(width: labelWidth, alignment: .leading)
            value()
                .environment(\.kRowHovered, isHovering)
            Spacer(minLength: 0)
        }
        .kQuietRow(isHovering: $isHovering, height: Metrics.controlRegular)
        .accessibilityElement(children: .combine)
    }
}

public extension KPropertyRow where Value == Text {
    /// Plain text value. `isPlaceholder` = nothing set yet ("Never", "None"): tertiary.
    init(_ label: String, value: String, isPlaceholder: Bool = false) {
        self.init(label) {
            Text(value)
                .font(Typo.row)
                .foregroundStyle(isPlaceholder ? Tok.textTertiary : Tok.textPrimary)
        }
    }
}
