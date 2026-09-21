// Kronos/DesignSystem/DesignGallerySidebarSection.swift
// Gallery section: both sidebar display modes side by side, plus the mode toggle.
// Project identity pickers live in DesignGalleryPickersSection.
// KSectionHeader owns its own vertical rhythm (20pt above / 6pt below, spec B1), so this
// demo only supplies Metrics.sidebarRowVGap between consecutive rows — no manual spacers.
import SwiftUI

struct DesignGallerySidebarSection: View {
    @State private var mode: KSidebarMode = .iconsAndText

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x4) {
            GallerySectionTitle(title: "Sidebar — two display modes")

            KSidebarModeToggle(mode: $mode)

            HStack(alignment: .top, spacing: Space.x6) {
                sidebarDemo(mode: .iconsAndText, label: "iconsAndText (\(Int(Metrics.sidebarDefault)) pt)")
                sidebarDemo(mode: .iconsOnly, label: "iconsOnly rail (\(Int(Metrics.sidebarRail)) pt)")
            }
        }
    }

    private func sidebarDemo(mode demoMode: KSidebarMode, label: String) -> some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            Text(label).font(Typo.meta).foregroundStyle(Tok.textTertiary)
            VStack(alignment: .leading, spacing: Metrics.sidebarRowVGap) {
                KSectionHeader("Areas", trailingIcon: "plus", trailingLabel: "New area") {}
                KSidebarRow(title: "Inbox", leadingIcon: "inbox", count: 12, isSelected: true) {}
                KSidebarRow(title: "Today", leadingIcon: "sun", count: 4) {}
                KSidebarRow(title: "Someday", leadingIcon: "sparkles", count: 0) {}
                KSectionHeader("Projects") {}
                KSidebarRow(title: "Acme", glyphColor: KProjectPalette.swatches[6].color, glyphEmoji: "🚀", count: 1) {}
                KSidebarRow(title: "Archived project", leadingIcon: "folder", isArchived: true) {}
            }
            .padding(Metrics.sidebarOuterInset)
            .frame(width: demoMode.width)
            .background(Tok.bg)
            .kBorder(Tok.hairline, radius: Radius.card)
            .environment(\.kSidebarMode, demoMode)
        }
    }
}
