// Kronos/DesignSystem/DesignGallerySpacingSection.swift
// Gallery section: draws the sidebar row and list row with tick-mark rulers so the
// exact geometry (spec B1/B3) can be verified by eye, not just by reading token values.
// A single numeric legend line under each diagram carries all the measurements — no
// overlapping inline labels, since several of these gaps are narrower than their own
// text would be.
import SwiftUI

struct DesignGallerySpacingSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Space.x6) {
            GallerySectionTitle(title: "Spacing — measured geometry")
            sidebarAlignmentDiagram
            railAlignmentDiagram
            listRowDiagram
        }
    }

    /// Stacks a system-view row (icon) directly above a project row (glyph) with a
    /// vertical guideline through the icon column's centre — proves the two leading
    /// glyphs share the same x-axis regardless of leading kind (spec B1 item 3).
    private var sidebarAlignmentDiagram: some View {
        let iconCentre = Metrics.sidebarRowLeading + Metrics.sidebarIconBox / 2
        return VStack(alignment: .leading, spacing: Space.x1) {
            Text("Sidebar row (iconsAndText) — icon vs. project glyph, same axis").font(Typo.meta).foregroundStyle(Tok.textTertiary)
            ZStack(alignment: .topLeading) {
                // Neutral grey glyph here on purpose: this crop is measured for zero
                // colour (spec G5) — the alignment proof does not need the swatch hue,
                // only the sidebar/pickers crops are allowed to show project colour.
                VStack(spacing: Metrics.sidebarRowVGap) {
                    KSidebarRow(title: "Today", leadingIcon: "sun", count: 4, isSelected: true) {}
                    KSidebarRow(title: "Acme", glyphColor: Tok.textDisabled, glyphEmoji: nil, count: 1) {}
                }
                .frame(width: 320)
                .environment(\.kSidebarMode, .iconsAndText)
                // Guideline through the icon column's centre, spanning both rows.
                Rectangle()
                    .fill(Tok.textDisabled.opacity(0.5))
                    .frame(width: 1, height: Metrics.sidebarRowHeight * 2 + Metrics.sidebarRowVGap)
                    .offset(x: iconCentre)
                ruler(width: 320, ticks: [
                    0, Metrics.sidebarRowLeading, Metrics.sidebarRowLeading + Metrics.sidebarIconBox,
                    Metrics.sidebarRowLeading + Metrics.sidebarIconBox + Metrics.sidebarIconTextGap,
                ], y: Metrics.sidebarRowHeight * 2 + Metrics.sidebarRowVGap)
            }
            .frame(height: Metrics.sidebarRowHeight * 2 + Metrics.sidebarRowVGap + 14)
            Text("row height \(Int(Metrics.sidebarRowHeight)) · leading \(Int(Metrics.sidebarRowLeading)) · icon \(Int(Metrics.sidebarIconBox)) · gap \(Int(Metrics.sidebarIconTextGap)) · trailing \(Int(Metrics.sidebarRowTrailing)) · selection bar \(Int(Metrics.sidebarSelectionBarWidth))pt inset \(Int(Metrics.sidebarSelectionBarInset))pt")
                .font(Typo.mono).foregroundStyle(Tok.textTertiary)
        }
    }

    private var railAlignmentDiagram: some View {
        VStack(alignment: .leading, spacing: Space.x1) {
            Text("Sidebar rail (iconsOnly) — icon vs. project glyph, centred").font(Typo.meta).foregroundStyle(Tok.textTertiary)
            HStack(spacing: 0) {
                KSidebarRow(title: "Today", leadingIcon: "sun", count: 4, isSelected: true) {}
                KSidebarRow(title: "Acme", glyphColor: Tok.textDisabled, glyphEmoji: nil, count: 1) {}
            }
            .frame(width: Metrics.sidebarRail * 2, height: Metrics.sidebarRowHeight)
            .environment(\.kSidebarMode, .iconsOnly)
            Text("rail width \(Int(Metrics.sidebarRail)) · icon size \(Int(Metrics.sidebarRailIconSize)) — both glyph kinds centred in the same column")
                .font(Typo.mono).foregroundStyle(Tok.textTertiary)
        }
    }

    private var listRowDiagram: some View {
        VStack(alignment: .leading, spacing: Space.x1) {
            Text("List row").font(Typo.meta).foregroundStyle(Tok.textTertiary)
            ZStack(alignment: .topLeading) {
                KListRow(isSelected: true, isChecked: false, accessibilityLabel: "Sample task", onToggle: {}, onSelect: {}) {
                    Text("Sample task").font(Typo.row).foregroundStyle(Tok.textPrimary)
                } trailing: {
                    KDeadlineLabel(text: "Today")
                }
                .frame(width: 420)
                ruler(width: 420, ticks: [
                    0, Metrics.listRowLeading, Metrics.listRowLeading + Metrics.listCheckboxSize,
                    Metrics.listRowLeading + Metrics.listCheckboxSize + Metrics.listCheckboxTitleGap,
                ], y: Metrics.rowHeight)
            }
            .frame(height: Metrics.rowHeight + 14)
            Text("row height \(Int(Metrics.rowHeight)) · leading \(Int(Metrics.listRowLeading)) · checkbox \(Int(Metrics.listCheckboxSize)) · gap \(Int(Metrics.listCheckboxTitleGap)) · trailing \(Int(Metrics.listRowTrailing)) · slot gap \(Int(Metrics.listTrailingSlotGap))")
                .font(Typo.mono).foregroundStyle(Tok.textTertiary)
        }
    }

    /// A tick mark at each named x-offset, just below the row — a visual ruler that
    /// never overlaps, unlike inline text labels crammed into narrow gaps.
    private func ruler(width: CGFloat, ticks: [CGFloat], y: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(ticks.enumerated()), id: \.offset) { _, x in
                Rectangle()
                    .fill(Tok.textDisabled)
                    .frame(width: 1, height: 6)
                    .offset(x: x, y: y + 2)
            }
        }
        .frame(width: width, alignment: .topLeading)
    }
}
