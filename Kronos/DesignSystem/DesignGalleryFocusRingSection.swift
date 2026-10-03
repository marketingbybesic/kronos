// Kronos/DesignSystem/DesignGalleryFocusRingSection.swift
// Gallery section: the one keyboard-focus ring on every control that wears it (button, chip,
// inspector chip, checkbox, steps checkbox) plus the drag nest outline, solid and dashed. A
// snapshot cannot carry a live focus event, so the ring is forced on from outside with the
// same `kFocusRing` call and radius each control uses itself. Rows carry no ring by design
// (selection fill + bar), shown here as a selected row with the nest outline on it.
import SwiftUI

struct DesignGalleryFocusRingSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Space.x5) {
            GallerySectionTitle(title: "Focus ring and nest outline")
            HStack(spacing: Space.x5) {
                Button("Save view") {}.kButton(.primary).kFocusRing(true, radius: Radius.control)
                Button("Cancel") {}.kButton(.secondary).kFocusRing(true, radius: Radius.control)
                Button { } label: { Icon("filter") }.kButton(.icon).kFocusRing(true, radius: Radius.control)
            }
            HStack(spacing: Space.x5) {
                KChip("Status is Todo", trailing: .chevron) {}
                    .fixedSize()
                    .kFocusRing(true, radius: Radius.chip)
                KChip("Acme", leading: { KProjectGlyph(color: .orange, emoji: "🌵", size: Metrics.iconS) })
                    .fixedSize()
                    .kFocusRing(true, radius: Radius.chip)
                KCheckbox(isChecked: false, size: Metrics.iconL, label: "Step") {}
                    .kFocusRing(true, radius: max(Metrics.iconL, Metrics.minHit) / 2, circular: true)
                KCheckbox(isChecked: true, size: Metrics.iconL, label: "Step") {}
                    .kFocusRing(true, radius: max(Metrics.iconL, Metrics.minHit) / 2, circular: true)
            }
            // Three states. Selection = the app's own fill + bar, no ring added on top.
            // Focus = the ring + faint wash (controls above). Nest target = dashed ring + stronger wash.
            VStack(alignment: .leading, spacing: Space.x4) {
                stateRow("Selection: fill and bar only", selected: true, outline: nil)
                stateRow("Drag target: nest under this row", selected: false, outline: false)
                stateRow("Drag target: attach as link (dashed)", selected: false, outline: true)
            }
        }
    }

    private func stateRow(_ title: String, selected: Bool, outline dashed: Bool?) -> some View {
        KListRow(isSelected: selected, isChecked: false, accessibilityLabel: title,
                 onToggle: {}, onSelect: {}) {
            Text(title).font(Typo.row).foregroundStyle(Tok.textPrimary)
        }
        .frame(width: 320, height: 36)
        .overlay { if let dashed { KNestOutline(radius: Radius.row, dashed: dashed) } }
    }
}
