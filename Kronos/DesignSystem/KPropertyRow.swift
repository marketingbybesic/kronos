// Kronos/DesignSystem/KPropertyRow.swift
// Style G's borderless property list row (the inspector stops being a form): a fixed,
// tertiary label column (`Metrics.propertyLabelColumn`, 96) and the value next to it, a
// full-row hover fill, no box. The value is any view — plain text, an indicator, a
// KAttributeMenu — so the control "appears on click" by being the value itself.
// Rows inside a `KPropertyList` share one rhythm: a hairline above every row except the
// first, so a property block reads as one table. A bare row (outside a list) draws none.
// Usage: KPropertyList {
//            KPropertyRow("Deadline") { KDeadlineLabel(text: "15 Sep", carryDays: 4) }
//            KPropertyRow("Status", value: "To do")
//        }
import SwiftUI

private struct KPropertyDividersKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set by `KPropertyList`: its rows draw the hairline above themselves.
    var kPropertyDividers: Bool {
        get { self[KPropertyDividersKey.self] }
        set { self[KPropertyDividersKey.self] = newValue }
    }
}

public struct KPropertyRow<Value: View>: View {
    let label: String
    var labelWidth: CGFloat
    @ViewBuilder let value: () -> Value
    @State private var isHovering = false
    @Environment(\.kPropertyDividers) private var showsDivider

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
        .overlay(alignment: .top) {
            if showsDivider { KHairline() }
        }
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

/// A block of `KPropertyRow`s with one consistent divider rule: a hairline between every two
/// rows, none above the first. Each row draws the hairline above itself; the list masks its own
/// top hairline-width, which hides exactly the first row's. Rows stack with no spacing.
public struct KPropertyList<Content: View>: View {
    @ViewBuilder let content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .environment(\.kPropertyDividers, true)
        .mask(alignment: .top) {
            Rectangle().padding(.top, Metrics.hairline)
        }
    }
}
