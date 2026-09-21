// Kronos/DesignSystem/DesignGalleryAttributesSection.swift
// Gallery section: the three first-class task attributes — effort, priority, deadline —
// as row indicators and as editable menus. The indicators/menus are data-agnostic
// (Int level, not an enum) so the design system never declares a type that could
// collide with KronosCore's own KPriority/KEffort; this gallery uses a private sample
// fixture type (never a "K…" name) purely to drive the demo.
import SwiftUI

/// Gallery-only sample data — a real screen leaf passes its KronosCore.KPriority cases
/// into KAttributeMenu/KPriorityIndicator instead of this type.
private struct GallerySamplePriority: Identifiable, Hashable {
    let id: Int
    let title: String
    static let all: [GallerySamplePriority] = [
        .init(id: 0, title: "No priority"), .init(id: 1, title: "Low"),
        .init(id: 2, title: "Medium"), .init(id: 3, title: "High"), .init(id: 4, title: "Urgent"),
    ]
}

private struct GallerySampleEffort: Identifiable, Hashable {
    let id: Int
    let title: String
    static let all: [GallerySampleEffort] = [
        .init(id: 0, title: "None"), .init(id: 1, title: "XS"), .init(id: 2, title: "S"),
        .init(id: 3, title: "M"), .init(id: 4, title: "L"), .init(id: 5, title: "XL"),
    ]
}

struct DesignGalleryAttributesSection: View {
    @State private var effort = GallerySampleEffort.all[3]
    @State private var priority = GallerySamplePriority.all[3]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x4) {
            GallerySectionTitle(title: "Task attributes — effort, priority, deadline")

            VStack(alignment: .leading, spacing: Space.x2) {
                Text("KEffortIndicator — every level").font(Typo.meta).foregroundStyle(Tok.textTertiary)
                HStack(spacing: Space.x5) {
                    ForEach(GallerySampleEffort.all) { e in
                        KEffortIndicator(level: e.id, of: 5, label: e.title)
                    }
                }
            }

            VStack(alignment: .leading, spacing: Space.x2) {
                Text("KPriorityIndicator — every level (urgent is a shape, never a colour)")
                    .font(Typo.meta).foregroundStyle(Tok.textTertiary)
                HStack(spacing: Space.x5) {
                    ForEach(GallerySamplePriority.all) { p in
                        VStack(spacing: Space.x1) {
                            KPriorityIndicator(level: p.id, of: 4, label: p.title)
                            Text(p.title).font(Typo.meta).foregroundStyle(Tok.textTertiary)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: Space.x2) {
                Text("KDeadlineLabel — calm overdue, no red").font(Typo.meta).foregroundStyle(Tok.textTertiary)
                HStack(spacing: Space.x5) {
                    KDeadlineLabel(text: "Today")
                    KDeadlineLabel(text: "Tomorrow")
                    KDeadlineLabel(text: "Today", carryDays: 3)
                    KDeadlineLabel(text: "15 Sep", isDone: true)
                }
            }

            VStack(alignment: .leading, spacing: Space.x2) {
                Text("KAttributeMenu — editable form").font(Typo.meta).foregroundStyle(Tok.textTertiary)
                HStack(spacing: Space.x4) {
                    KAttributeMenu(options: GallerySampleEffort.all, selected: effort, title: { $0.title },
                                   level: { $0.id }, steps: 5, kind: .effort) { effort = $0 }
                    KAttributeMenu(options: GallerySamplePriority.all, selected: priority, title: { $0.title },
                                   level: { $0.id }, steps: 4, kind: .priority) { priority = $0 }
                }
            }

            VStack(alignment: .leading, spacing: Space.x2) {
                Text("Composed on a row").font(Typo.meta).foregroundStyle(Tok.textTertiary)
                KListRow(isChecked: false, accessibilityLabel: "Pripremiti prezentaciju, high priority, medium effort, due tomorrow",
                         onToggle: {}, onSelect: {}) {
                    HStack(spacing: Space.x2) {
                        KPriorityIndicator(level: 3, of: 4, label: "High")
                        Text("Pripremiti prezentaciju").font(Typo.row).foregroundStyle(Tok.textPrimary)
                    }
                } trailing: {
                    HStack(spacing: Space.x3) {
                        KEffortIndicator(level: 3, of: 5, label: nil, showLabel: false)
                        KDeadlineLabel(text: "Tomorrow")
                    }
                }
                .frame(width: 420)
            }
        }
    }
}
