// Kronos/DesignSystem/KSortBuilder.swift
// One sort rule (field + its own ascending/descending toggle + drag handle + remove),
// and the container listing rules in priority order with "Add sort". Generic over
// KSortFilterField so the design system never imports KronosCore.
// Usage:
//   KSortBuilder(rules: $sortRules, availableFields: fields) { KSortFilterField(...) }
import SwiftUI

public struct KSortRule: Identifiable {
    /// Stable across rebuilds when the caller passes one (the row keeps its identity while its
    /// direction changes); a fresh one otherwise.
    public let id: AnyHashable
    public var field: KSortFilterField
    public var ascending: Bool

    public init(id: AnyHashable = AnyHashable(UUID()), field: KSortFilterField, ascending: Bool = true) {
        self.id = id
        self.field = field
        self.ascending = ascending
    }
}

/// A single sort rule row: drag handle · field menu (with its own dropdown affordance)
/// · direction toggle (a small square button with an up/down ARROW, never a chevron —
/// a chevron reads as "this opens a menu", which the direction toggle does not do) ·
/// remove. `onPickField` is optional: pass it to let the row's own field name open a
/// menu of the other available fields; omit it to keep the field name static.
public struct KSortRuleRow: View {
    @Binding var rule: KSortRule
    var availableFields: [KSortFilterField] = []
    var onPickField: ((KSortFilterField) -> Void)?
    let onRemove: () -> Void
    @State private var isFieldMenuHovering = false
    @State private var isRowHovering = false

    public init(rule: Binding<KSortRule>, availableFields: [KSortFilterField] = [],
                onPickField: ((KSortFilterField) -> Void)? = nil, onRemove: @escaping () -> Void) {
        self._rule = rule
        self.availableFields = availableFields
        self.onPickField = onPickField
        self.onRemove = onRemove
    }

    public var body: some View {
        HStack(spacing: Space.x2) {
            Icon("grip-vertical", size: Metrics.iconS)
                .foregroundStyle(Tok.textDisabled)
            fieldMenu
            Spacer(minLength: Space.x2)
            directionToggle
            removeButton
        }
        .kQuietRow(isHovering: $isRowHovering)
    }

    @ViewBuilder
    private var fieldMenu: some View {
        if let onPickField, !availableFields.isEmpty {
            Menu {
                ForEach(availableFields) { field in
                    Button(field.name) { onPickField(field) }
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: Space.x1) {
                    Icon(rule.field.symbol, size: Metrics.iconM)
                        .foregroundStyle(Tok.textTertiary)
                    Text(rule.field.name)
                        .font(Typo.row)
                        .foregroundStyle(Tok.textPrimary)
                    // Field-name dropdown affordance: textTertiary at rest reads too
                    // faint to register as "this opens a menu" (measured defect) —
                    // textSecondary on hover makes the affordance legible without
                    // adding a border/fill this row doesn't otherwise have.
                    Icon("chevron-up-down", size: Metrics.iconXS)
                        .foregroundStyle(isFieldMenuHovering ? Tok.textSecondary : Tok.textTertiary)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .onHover { isFieldMenuHovering = $0 }
            .animation(Motion.curve(Motion.fast), value: isFieldMenuHovering)
        } else {
            HStack(spacing: Space.x1) {
                Icon(rule.field.symbol, size: Metrics.iconM)
                    .foregroundStyle(Tok.textTertiary)
                Text(rule.field.name)
                    .font(Typo.row)
                    .foregroundStyle(Tok.textPrimary)
            }
        }
    }

    private var directionToggle: some View {
        Button {
            rule.ascending.toggle()
        } label: {
            Icon(rule.ascending ? "arrow-up" : "arrow-down", size: Metrics.iconM)
                .foregroundStyle(Tok.textSecondary)
                .frame(width: Metrics.minHit, height: Metrics.minHit)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(localized: rule.ascending ? "viewoptions.sort.ascending" : "viewoptions.sort.descending"))
        .accessibilityLabel(String(localized: rule.ascending ? "viewoptions.sort.ascending" : "viewoptions.sort.descending"))
        .accessibilityHint(String(localized: "viewoptions.sort.direction.hint", defaultValue: "Reverses the sort direction"))
    }

    /// The size and hit shape live INSIDE the label (like `directionToggle`): a plain-style button is
    /// pressable only on its label's pixels, so with the frame outside only the ~8 pt glyph took a click.
    private var removeButton: some View {
        Button(action: onRemove) {
            Icon("x", size: Metrics.iconXS)
                .foregroundStyle(isRowHovering ? Tok.textSecondary : Tok.textDisabled)
                .frame(width: Metrics.minHit, height: Metrics.minHit)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .uiTestAnchor("sort.remove.\(String(describing: rule.field.id.base))")
        .accessibilityLabel(String(localized: "viewoptions.sort.remove.accessibility", defaultValue: "Remove sort rule \(rule.field.name)"))
    }
}

/// Lists sort rules in priority order (first rule wins ties on the second, etc.) with
/// an "Add sort" menu of the fields not already used.
public struct KSortBuilder: View {
    @Binding var rules: [KSortRule]
    let availableFields: [KSortFilterField]

    public init(rules: Binding<[KSortRule]>, availableFields: [KSortFilterField]) {
        self._rules = rules
        self.availableFields = availableFields
    }

    private var unusedFields: [KSortFilterField] {
        let used = Set(rules.map(\.field.id))
        return availableFields.filter { !used.contains($0.id) }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            // Rows are addressed by POSITION, never by `rule.id`: a caller whose binding rebuilds its rules
            // on every read (the app's does) hands out fresh ids each time, so an id captured when the row
            // was drawn matched nothing when the remove button was pressed, and the X did nothing.
            ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                // Re-picking this row's own field offers its current field plus every
                // field not already used by a DIFFERENT row.
                let usedByOthers = Set(rules.enumerated().filter { $0.offset != index }.map(\.element.field.id))
                let pickableFields = availableFields.filter { !usedByOthers.contains($0.id) }
                let row = Binding<KSortRule>(
                    get: { rules.indices.contains(index) ? rules[index] : rule },
                    set: { if rules.indices.contains(index) { rules[index] = $0 } })
                KSortRuleRow(rule: row, availableFields: pickableFields) { field in
                    if rules.indices.contains(index) { rules[index].field = field }
                } onRemove: {
                    if rules.indices.contains(index) { rules.remove(at: index) }
                }
            }
            if !unusedFields.isEmpty {
                Menu {
                    ForEach(unusedFields) { field in
                        Button(field.name) {
                            rules.append(KSortRule(field: field))
                        }
                    }
                } label: {
                    HStack(spacing: Space.x1) {
                        Icon("plus", size: Metrics.iconS)
                        Text(String(localized: "viewoptions.sort.add")).font(Typo.row)
                    }
                    .foregroundStyle(Tok.textTertiary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }
}
