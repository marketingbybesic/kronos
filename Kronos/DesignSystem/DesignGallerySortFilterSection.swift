// Kronos/DesignSystem/DesignGallerySortFilterSection.swift
// Gallery section: sort/filter builder primitives, the rev-4 view-options icon button +
// active-rules bar + popover shell. Neutral sample data ("Acme", "Globex") — no client names.
import SwiftUI

private let demoFields: [KSortFilterField] = [
    KSortFilterField(id: "priority", name: "Priority", symbol: "flag"),
    KSortFilterField(id: "deadline", name: "Deadline", symbol: "calendar"),
    KSortFilterField(id: "project", name: "Project", symbol: "folder"),
    KSortFilterField(id: "status", name: "Status", symbol: "check"),
]

struct DesignGallerySortFilterSection: View {
    @State private var sortRules: [KSortRule] = [
        KSortRule(field: demoFields[0], ascending: false),
        KSortRule(field: demoFields[1], ascending: true),
    ]
    @State private var filterRules: [KFilterRule] = [
        KFilterRule(field: demoFields[3], valueSummary: "Todo, In progress"),
        KFilterRule(field: demoFields[2], isNegated: true, valueSummary: "Globex"),
    ]
    // A four-status value summary — long enough that, before the layout fix, it
    // collapsed the field label and operator into overlapping glyphs.
    @State private var longFilterRules: [KFilterRule] = [
        KFilterRule(field: demoFields[3], valueSummary: "Todo, In progress, Blocked, Done"),
    ]
    @State private var showCompleted = false
    @State private var showPopover = false

    private var activeCount: Int { sortRules.count + filterRules.count }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x4) {
            GallerySectionTitle(title: "Sort & filter (rev 4)")

            VStack(alignment: .leading, spacing: Space.x2) {
                Text("KViewOptionsIconButton — the toolbar's one entry point").font(Typo.meta).foregroundStyle(Tok.textTertiary)
                HStack(spacing: Space.x3) {
                    KViewOptionsIconButton(activeCount: activeCount) { showPopover.toggle() }
                    KViewOptionsIconButton(activeCount: 0) {}
                }
            }

            VStack(alignment: .leading, spacing: Space.x2) {
                Text("KActiveRulesBar — shown only when rules are active").font(Typo.meta).foregroundStyle(Tok.textTertiary)
                KActiveRulesBar(chips: [
                    .init(id: "s0", text: "Priority ↓", onRemove: {}),
                    .init(id: "f0", text: "Status is Todo, In progress", onRemove: {}),
                    .init(id: "f1", text: "Project is not Globex", onRemove: {}),
                ], onReset: {})
                .frame(width: 640)
            }

            HStack(alignment: .top, spacing: Space.x6) {
                VStack(alignment: .leading, spacing: Space.x2) {
                    Text("KSortBuilder — arrow direction, field has its own dropdown").font(Typo.meta).foregroundStyle(Tok.textTertiary)
                    KSortBuilder(rules: $sortRules, availableFields: demoFields).frame(width: 320)
                }
                VStack(alignment: .leading, spacing: Space.x2) {
                    Text("KFilterBuilder").font(Typo.meta).foregroundStyle(Tok.textTertiary)
                    KFilterBuilder(rules: $filterRules, availableFields: demoFields, onAdd: { field in
                        filterRules.append(KFilterRule(field: field, valueSummary: "…"))
                    }, valueMenu: { _ in
                        Button("Todo") {}
                        Button("In progress") {}
                    })
                    .frame(width: 340)
                }
            }

            VStack(alignment: .leading, spacing: Space.x2) {
                Text("KFilterRuleRow — four statuses, stays legible (truncates, full text in .help)").font(Typo.meta).foregroundStyle(Tok.textTertiary)
                KFilterBuilder(rules: $longFilterRules, availableFields: demoFields, onAdd: { field in
                    longFilterRules.append(KFilterRule(field: field, valueSummary: "…"))
                }, valueMenu: { _ in
                    Button("Todo") {}
                    Button("In progress") {}
                })
                .frame(width: 260)
            }

            VStack(alignment: .leading, spacing: Space.x2) {
                Text("KViewOptionsPopover — Sort / Filter / Display, one popover").font(Typo.meta).foregroundStyle(Tok.textTertiary)
                KViewOptionsPopover {
                    KSortBuilder(rules: $sortRules, availableFields: demoFields)
                } filter: {
                    KFilterBuilder(rules: $filterRules, availableFields: demoFields, onAdd: { field in
                        filterRules.append(KFilterRule(field: field, valueSummary: "…"))
                    }, valueMenu: { _ in
                        Button("Todo") {}
                        Button("In progress") {}
                    })
                } display: {
                    VStack(alignment: .leading, spacing: Space.x3) {
                        KToggleRow("Show completed", isOn: $showCompleted)
                        Button("Save as view…") {}.kButton(.secondary)
                    }
                }
            }
        }
    }
}
