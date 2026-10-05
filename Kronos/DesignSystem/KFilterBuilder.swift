// Kronos/DesignSystem/KFilterBuilder.swift
// One filter rule (field + operator summary + value menu + remove), and the container
// listing rules with "Add filter". Generic over KSortFilterField, values are opaque
// display strings supplied by the caller (the real Status/Priority/Project types live
// in KronosCore, which this module never imports).
// Usage:
//   KFilterBuilder(rules: $filterRules, availableFields: fields, valueMenu: { field, onPick in ... })
import SwiftUI

public struct KFilterRule: Identifiable {
    /// Stable across rebuilds when the caller passes one (a row keeps its identity, and so its focus and
    /// open menu, while its value changes); a fresh one otherwise.
    public let id: AnyHashable
    public var field: KSortFilterField
    public var isNegated: Bool          // false = "is", true = "is not"
    public var valueSummary: String     // e.g. "Todo, In progress" or "3 projects"
    /// A row added but without a value yet: its summary is a prompt, drawn quieter.
    public var isPlaceholder: Bool

    public init(id: AnyHashable = AnyHashable(UUID()), field: KSortFilterField, isNegated: Bool = false,
                valueSummary: String, isPlaceholder: Bool = false) {
        self.id = id
        self.field = field
        self.isNegated = isNegated
        self.valueSummary = valueSummary
        self.isPlaceholder = isPlaceholder
    }
}

/// A single filter rule row: field, "is"/"is not" toggle, value summary (opens a
/// caller-supplied menu), remove.
public struct KFilterRuleRow<ValueMenu: View>: View {
    @Binding var rule: KFilterRule
    let onRemove: () -> Void
    /// A field whose value is typed (Text) edits here instead of in a menu.
    var textValue: Binding<String>?
    var textPlaceholder: String
    @ViewBuilder let valueMenu: () -> ValueMenu
    @State private var isRowHovering = false

    public init(rule: Binding<KFilterRule>, onRemove: @escaping () -> Void,
                textValue: Binding<String>? = nil, textPlaceholder: String = "",
                @ViewBuilder valueMenu: @escaping () -> ValueMenu) {
        self._rule = rule
        self.onRemove = onRemove
        self.textValue = textValue
        self.textPlaceholder = textPlaceholder
        self.valueMenu = valueMenu
    }

    public var body: some View {
        HStack(spacing: Space.x2) {
            fieldLabel
            negationToggle
            if let textValue {
                KTextField(textPlaceholder, text: textValue, autofocus: rule.isPlaceholder)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                valueMenuButton
            }
            removeButton
        }
        .kQuietRow(isHovering: $isRowHovering)
        .uiTestAnchor("filter.row.\(String(describing: rule.field.id.base))")
    }

    private var fieldLabel: some View {
        HStack(spacing: Space.x2) {
            Icon(rule.field.symbol, size: Metrics.iconM)
                .foregroundStyle(Tok.textTertiary)
            Text(rule.field.name)
                .font(Typo.row)
                .foregroundStyle(Tok.textSecondary)
                .lineLimit(1)
        }
        // Field label always wins layout over the value summary — a long value
        // summary must never compress the field name/operator into overlapping
        // glyphs (measured regression with a four-status value: fixed here by
        // giving this and the operator toggle fixed minimum widths + priority,
        // and letting the value summary alone shrink/truncate).
        .frame(width: Metrics.ruleFieldColumn, alignment: .leading)
        .layoutPriority(1)
    }

    private var negationToggle: some View {
        Button {
            rule.isNegated.toggle()
        } label: {
            Text(String(localized: rule.isNegated ? "viewoptions.op.isnot" : "viewoptions.op.is"))
                .font(Typo.row)
                .foregroundStyle(Tok.textTertiary)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        // Fixed operator column: "is" and "is not" differ in width, and the VALUE column must
        // start at the same x on every row (carried defect).
        .frame(width: Metrics.ruleOperatorColumn, height: Metrics.minHit, alignment: .leading)
        .layoutPriority(1)
        .accessibilityLabel(String(localized: rule.isNegated ? "viewoptions.op.isnot" : "viewoptions.op.is"))
        .accessibilityHint(String(localized: "viewoptions.filter.invert.hint", defaultValue: "Inverts this filter"))
    }

    /// A borderless `Menu` that is squeezed drops its own leading inset before it truncates,
    /// which moved a long value 4 pt left of a short one. So the menu is never squeezed: it is
    /// always laid out at its ideal width, and the first pre-shortened summary that fits wins.
    private var valueMenuButton: some View {
        ViewThatFits(in: .horizontal) {
            valueMenu(limit: .max)
            valueMenu(limit: 28)
            valueMenu(limit: 20)
            valueMenu(limit: 14)
            valueMenu(limit: 9)
            valueMenu(limit: 5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(rule.valueSummary)
    }

    private func valueMenu(limit: Int) -> some View {
        let summary = rule.valueSummary
        let shown = summary.count > limit ? String(summary.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…" : summary
        return Menu {
            valueMenu()
        } label: {
            Text(shown)
                .font(Typo.row)
                .foregroundStyle(rule.isPlaceholder ? Tok.textTertiary : Tok.textPrimary)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// The size and hit shape live INSIDE the label: a plain-style button is pressable only on its
    /// label's pixels, so with the frame outside only the ~8 pt glyph took a click.
    private var removeButton: some View {
        Button(action: onRemove) {
            Icon("x", size: Metrics.iconXS)
                .foregroundStyle(isRowHovering ? Tok.textSecondary : Tok.textDisabled)
                .frame(width: Metrics.minHit, height: Metrics.minHit)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .uiTestAnchor("filter.remove.\(String(describing: rule.field.id.base))")
        .accessibilityLabel(String(localized: "viewoptions.filter.remove.accessibility", defaultValue: "Remove filter \(rule.field.name)"))
    }
}

/// Lists filter rules (AND between rules) with an "Add filter" menu of remaining fields.
public struct KFilterBuilder<ValueMenu: View>: View {
    @Binding var rules: [KFilterRule]
    let availableFields: [KSortFilterField]
    @ViewBuilder let valueMenu: (KSortFilterField) -> ValueMenu
    let onAdd: (KSortFilterField) -> Void
    let textValue: (KSortFilterField) -> Binding<String>?
    let textPlaceholder: String

    /// `availableFields` are the fields still offered by "Add filter" (the caller leaves out the ones
    /// that already have a row). `textValue` answers a binding for a field whose value is typed.
    public init(rules: Binding<[KFilterRule]>, availableFields: [KSortFilterField],
                textValue: @escaping (KSortFilterField) -> Binding<String>? = { _ in nil },
                textPlaceholder: String = "",
                onAdd: @escaping (KSortFilterField) -> Void,
                @ViewBuilder valueMenu: @escaping (KSortFilterField) -> ValueMenu) {
        self._rules = rules
        self.availableFields = availableFields
        self.textValue = textValue
        self.textPlaceholder = textPlaceholder
        self.onAdd = onAdd
        self.valueMenu = valueMenu
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            // By position, for the reason given in KSortBuilder: ids captured at draw time need not
            // survive a caller that rebuilds its rules on every read.
            ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                let row = Binding<KFilterRule>(
                    get: { rules.indices.contains(index) ? rules[index] : rule },
                    set: { if rules.indices.contains(index) { rules[index] = $0 } })
                KFilterRuleRow(rule: row, onRemove: {
                    if rules.indices.contains(index) { rules.remove(at: index) }
                }, textValue: textValue(rule.field), textPlaceholder: textPlaceholder) {
                    valueMenu(rule.field)
                }
            }
            if !availableFields.isEmpty {
                Menu {
                    ForEach(availableFields) { field in
                        Button(field.name) { onAdd(field) }
                    }
                } label: {
                    HStack(spacing: Space.x1) {
                        Icon("plus", size: Metrics.iconS)
                        Text(String(localized: "viewoptions.filter.add")).font(Typo.row)
                    }
                    .foregroundStyle(Tok.textTertiary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .uiTestAnchor("filter.add")
            }
        }
    }
}
