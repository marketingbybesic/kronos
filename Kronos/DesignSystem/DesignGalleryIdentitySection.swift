// Kronos/DesignSystem/DesignGalleryIdentitySection.swift
// Gallery sections for rev 7: `identity` (project glyphs, icon picker, colour-mode switch),
// `sidebar-f` (the F sidebar composition) and `nowcard`. Each is rendered in all three
// colour modes by scripts/gallery-shot-main.swift; the mode arrives through the
// environment, so these sections never branch on it — exactly like a real screen.
// Sample names are neutral on purpose (gate-ds rejects real client names).
import SwiftUI

struct GallerySampleProject: Identifiable {
    let id: String
    let icon: String
    let hex: String
    let count: Int
    var isFocus = false

    static let all: [GallerySampleProject] = [
        .init(id: "Acme", icon: "briefcase", hex: "#5B8DEF", count: 7),
        .init(id: "Globex", icon: "landmark", hex: "#E8B339", count: 7),
        .init(id: "Initech Dental", icon: "tooth", hex: "#4CC2FF", count: 2),
        .init(id: "Northwind Bistro", icon: "utensils", hex: "#F2994A", count: 3, isFocus: true),
        .init(id: "Contoso Studio", icon: "camera", hex: "#A66BFF", count: 12),
        .init(id: "Fabrikam Motors", icon: "car", hex: "#3FB950", count: 2),
    ]
}

struct DesignGalleryIdentitySection: View {
    @Environment(\.chromaMode) private var chromaMode
    @State private var pickedIcon: String? = "utensils"

    private let extra: [GallerySampleProject] = [
        .init(id: "Clinic", icon: "stethoscope", hex: "#2DD4BF", count: 0),
        .init(id: "Campaign", icon: "megaphone", hex: "#C77DFF", count: 0),
        .init(id: "Brand", icon: "pen-tool", hex: "#F2C94C", count: 0),
        .init(id: "Launch", icon: "rocket", hex: "#8B7CF6", count: 0),
        .init(id: "Web", icon: "globe", hex: "#5CE1C4", count: 0),
        .init(id: "Course", icon: "graduation-cap", hex: "#C0C4CC", count: 0),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x8) {
            VStack(alignment: .leading, spacing: Space.x4) {
                GallerySectionTitle(title: "Project identity: icon + colour (mode: \(chromaMode.rawValue))")
                Text("KProjectGlyph is the only component that shows hue, always through Chroma.tint. One sample is the focus project.")
                    .font(Typo.meta).foregroundStyle(Tok.textTertiary)
                glyphGrid
            }
            HStack(alignment: .top, spacing: Space.x8) {
                VStack(alignment: .leading, spacing: Space.x3) {
                    GallerySectionTitle(title: "KIconPicker")
                    KIconPicker(selection: $pickedIcon, viewportHeight: nil)
                    Text(ProjectIconSet.unresolved.isEmpty
                         ? "\(ProjectIconSet.all.count)/\(ProjectIconSet.all.count) icons resolve on this machine"
                         : "UNRESOLVED: \(ProjectIconSet.unresolved.joined(separator: ", "))")
                        .font(Typo.meta).foregroundStyle(Tok.textTertiary)
                }
                VStack(alignment: .leading, spacing: Space.x4) {
                    GallerySectionTitle(title: "KChromaModeSwitch")
                    KChromaModeSwitch(mode: .constant(chromaMode))
                    KChromaModeSwitch(mode: .constant(chromaMode), showsLabels: true)
                    GallerySectionTitle(title: "Editor preview (plate)").padding(.top, Space.x4)
                    HStack(spacing: Space.x3) {
                        KProjectGlyph(icon: pickedIcon, colorHex: "#F2994A", isFocus: true, size: Metrics.iconXL + Space.x2, style: .plate)
                        KProjectGlyph(icon: pickedIcon, colorHex: "#F2994A", size: Metrics.iconXL + Space.x2, style: .plate)
                        KProjectGlyph(icon: nil, colorHex: "#F2994A", size: Metrics.iconXL + Space.x2, style: .plate)
                        // Legacy stores carry "circle" on every project: it must draw the dot, not a ring.
                        KProjectGlyph(icon: "circle", colorHex: "#F2994A", size: Metrics.iconXL + Space.x2, style: .plate)
                    }
                }
            }
        }
    }

    private var glyphGrid: some View {
        let columns = Array(repeating: GridItem(.fixed(150), spacing: Space.x4, alignment: .leading), count: 4)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: Space.x3) {
            ForEach(GallerySampleProject.all + extra) { project in
                HStack(spacing: Space.x2) {
                    KProjectGlyph(icon: project.icon, colorHex: project.hex, isFocus: project.isFocus, size: Metrics.iconL)
                    Text(project.id).font(Typo.row).foregroundStyle(Tok.textSecondary).lineLimit(1)
                }
            }
        }
    }
}

struct DesignGallerySidebarFSection: View {
    @Environment(\.chromaMode) private var chromaMode
    @State private var isClientsOpen = true

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x4) {
            GallerySectionTitle(title: "Sidebar F (mode: \(chromaMode.rawValue))")
            HStack(alignment: .top, spacing: Space.x6) {
                sidebar(.iconsAndText)
                sidebar(.iconsOnly)
            }
        }
    }

    private func sidebar(_ mode: KSidebarMode) -> some View {
        VStack(alignment: .leading, spacing: Metrics.sidebarRowVGap) {
            KSidebarRow(title: "Inbox", leadingIcon: "inbox", count: 0) {}
            KSidebarRow(title: "Today", leadingIcon: "sun", count: 3) {}
            KSidebarRow(title: "Next 7 days", leadingIcon: "calendar-days", count: 0) {}
            KSidebarRow(title: "Waiting", leadingIcon: "hourglass", count: 7) {}
            KSidebarRow(title: "Someday", leadingIcon: "sparkles", count: 5) {}
            KSidebarRow(title: "All", leadingIcon: "list-ordered", count: 37, isSelected: true) {}
            KSectionHeader("Areas", trailingIcon: "plus", trailingLabel: "New area") {}
            KSidebarRow(title: "Clients", isExpanded: isClientsOpen) { isClientsOpen.toggle() }
            ForEach(GallerySampleProject.all) { project in
                KSidebarRow(title: project.id, projectIcon: project.icon, colorHex: project.hex,
                            isFocus: project.isFocus, count: project.count, indent: 1) {}
            }
            KSidebarRow(title: "Studio", isExpanded: false) {}
            Spacer(minLength: Space.x6)
            KHairline()
            KSidebarRow(title: "Impuls", leadingIcon: "zap") {}
            if mode == .iconsAndText {
                HStack {
                    KChromaModeSwitch(mode: .constant(chromaMode))
                    Spacer()
                    Icon("sliders", size: Metrics.iconM).foregroundStyle(Tok.textTertiary)
                }
                .padding(.horizontal, Metrics.sidebarRowLeading)
                .padding(.top, Space.x2)
            }
        }
        .padding(Metrics.sidebarOuterInset)
        .frame(width: mode.width)
        .background(Tok.bg)
        .kBorder(Tok.hairline, radius: Radius.card)
        .environment(\.kSidebarMode, mode)
    }
}

struct DesignGalleryNowCardSection: View {
    @Environment(\.chromaMode) private var chromaMode

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x4) {
            GallerySectionTitle(title: "KNowCard (mode: \(chromaMode.rawValue))")
            KNowCard(firstMove: "Otvori Flow, učitaj cover iz story mape i kreni od slajda 2.",
                     title: "Carousel #1: proizvodnja u Flowu", remaining: 6,
                     projectIcon: "utensils", projectColorHex: "#F2994A", projectName: "Northwind Bistro",
                     attributes: {
                         KEffortIndicator(level: 3, of: 5, label: "M")
                         KPriorityIndicator(level: 2, of: 4, label: "Medium")
                         KDeadlineLabel(text: "15 Sep", carryDays: 4)
                     }, onComplete: {})
            KNowCard(firstMove: nil, title: "Send the September invoice to Acme", remaining: 1,
                     projectIcon: "briefcase", projectColorHex: "#5B8DEF", onComplete: {})
        }
        .frame(width: 640)
    }
}
