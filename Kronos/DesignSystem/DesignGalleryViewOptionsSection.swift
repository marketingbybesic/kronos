// Kronos/DesignSystem/DesignGalleryViewOptionsSection.swift
// Gallery section: the rev-4 view-options shell in isolation — the icon button with and
// without its badge, the active-rules bar with 3 chips, and the full three-section
// popover. Neutral sample data only.
import SwiftUI

private let viewOptionsFields: [KSortFilterField] = [
    KSortFilterField(id: "priority", name: "Priority", symbol: "flag"),
    KSortFilterField(id: "deadline", name: "Deadline", symbol: "calendar"),
    KSortFilterField(id: "project", name: "Project", symbol: "folder"),
]

struct DesignGalleryViewOptionsSection: View {
    @State private var sortRules: [KSortRule] = [KSortRule(field: viewOptionsFields[0], ascending: false)]
    @State private var filterRules: [KFilterRule] = [KFilterRule(field: viewOptionsFields[2], isNegated: true, valueSummary: "Globex")]
    @State private var showCompleted = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x4) {
            GallerySectionTitle(title: "View options (rev 4)")

            VStack(alignment: .leading, spacing: Space.x2) {
                Text("KViewOptionsIconButton — with and without the active-count badge").font(Typo.meta).foregroundStyle(Tok.textTertiary)
                HStack(spacing: Space.x4) {
                    KViewOptionsIconButton(activeCount: 2) {}
                    KViewOptionsIconButton(activeCount: 0) {}
                }
            }

            VStack(alignment: .leading, spacing: Space.x2) {
                Text("KActiveRulesBar — three chips + Reset").font(Typo.meta).foregroundStyle(Tok.textTertiary)
                KActiveRulesBar(chips: [
                    .init(id: "s0", text: "Priority ↓", onRemove: {}),
                    .init(id: "f0", text: "Deadline is Overdue", onRemove: {}),
                    .init(id: "f1", text: "Project is not Globex", onRemove: {}),
                ], onReset: {})
                .frame(width: 640)
            }

            VStack(alignment: .leading, spacing: Space.x2) {
                Text("KViewOptionsPopover — Sort / Filter / Display, one popover").font(Typo.meta).foregroundStyle(Tok.textTertiary)
                KViewOptionsPopover {
                    KSortBuilder(rules: $sortRules, availableFields: viewOptionsFields)
                } filter: {
                    KFilterBuilder(rules: $filterRules, availableFields: viewOptionsFields, onAdd: { field in
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
