// Kronos/DesignSystem/DesignGalleryListSection.swift
// Gallery section: KListRow states (the same three rows as before style G, for a fair
// before/after), then a style G composition — title primary, everything else a tone
// down, project glyph + quiet indicators on one trailing grid — and the borderless
// property list that replaces the inspector's boxed form. Glyphs here are neutral on
// purpose: this crop is measured for zero hue in every mode except via KProjectGlyph,
// and the gate shoots it in calm.
import SwiftUI

struct DesignGalleryListSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Space.x6) {
            VStack(alignment: .leading, spacing: Space.x1) {
                GallerySectionTitle(title: "List rows")
                KListRow(isChecked: false, accessibilityLabel: "Otvoriti racun za Acme, todo, due in 2 days",
                         onToggle: {}, onSelect: {}) {
                    Text("Otvoriti racun za Acme").font(Typo.row).foregroundStyle(Tok.textPrimary)
                } trailing: {
                    KDeadlineLabel(text: "2d")
                }
                KListRow(isSelected: true, isChecked: false, accessibilityLabel: "Otvoriti internet banku, todo",
                         onToggle: {}, onSelect: {}) {
                    Text("Otvoriti internet banku").font(Typo.row).foregroundStyle(Tok.textPrimary)
                }
                KListRow(isDone: true, isChecked: true, accessibilityLabel: "Mama mia, done",
                         onToggle: {}, onSelect: {}) {
                    Text("Mama mia").font(Typo.row).foregroundStyle(Tok.textTertiary).strikethrough()
                }
            }
            .frame(width: 420)

            VStack(alignment: .leading, spacing: 0) {
                GallerySectionTitle(title: "Style G row composition")
                sampleRow("Pripremiti ponudu za Globex: čišćenje, šablona, završna provjera", icon: "landmark", hex: "#E8B339",
                          project: "Globex", effort: 3, priority: 3, deadline: "sutra", isSelected: true)
                KHairline().padding(.leading, Metrics.listRowLeading + Metrics.listCheckboxSize + Metrics.listCheckboxTitleGap + Space.x2).padding(.trailing, Space.x1 + 2)
                sampleRow("Send the September invoice", icon: "briefcase", hex: "#5B8DEF",
                          project: "Acme", effort: 1, priority: 2, deadline: "pet")
                KHairline().padding(.leading, Metrics.listRowLeading + Metrics.listCheckboxSize + Metrics.listCheckboxTitleGap + Space.x2).padding(.trailing, Space.x1 + 2)
                sampleRow("Story set: brief", icon: "utensils", hex: "#F2994A",
                          project: "Northwind Bistro", effort: 0, priority: 0, deadline: nil)
            }
            .frame(width: 640)

            VStack(alignment: .leading, spacing: 0) {
                GallerySectionTitle(title: "KPropertyRow: borderless property list")
                KPropertyRow("Effort") { KEffortIndicator(level: 3, of: 5, label: "M") }
                KPropertyRow("Deadline") { KDeadlineLabel(text: "15 Sep", carryDays: 4) }
                KPropertyRow("Priority") {
                    HStack(spacing: Space.x2) {
                        KPriorityIndicator(level: 2, of: 4, label: "Medium")
                        Text("Medium").font(Typo.row).foregroundStyle(Tok.textPrimary)
                    }
                }
                KPropertyRow("Status", value: "To do")
                KPropertyRow("Repeat", value: "Never", isPlaceholder: true)
            }
            .frame(width: 320)
        }
    }

    private func sampleRow(_ title: String, icon: String, hex: String, project: String,
                           effort: Int, priority: Int, deadline: String?, isSelected: Bool = false) -> some View {
        KListRow(isSelected: isSelected, isChecked: false, accessibilityLabel: title, onToggle: {}, onSelect: {}) {
            Text(title).font(Typo.row).tracking(Tracking.row).foregroundStyle(Tok.textPrimary).lineLimit(1)
        } trailing: {
            HStack(spacing: Space.x1 + 2) {
                KProjectGlyph(icon: icon, colorHex: hex, size: Metrics.iconM)
                Text(project).font(Typo.meta).foregroundStyle(Tok.textTertiary).lineLimit(1)
            }
            .frame(width: 116, alignment: .leading)
            KEffortIndicator(level: effort, of: 5, label: nil, showLabel: false).opacity(effort == 0 ? 0 : 1)
            KPriorityIndicator(level: priority, of: 4, label: nil)
            Text(deadline ?? "").font(Typo.count).foregroundStyle(Tok.textSecondary)
                .frame(width: 36, alignment: .trailing)
        }
    }
}
