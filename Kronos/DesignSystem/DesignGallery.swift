// Kronos/DesignSystem/DesignGallery.swift
// Renders every token swatch and every component in every state on the OLED ground.
// This is the visual verification surface for the whole design system — see
// DesignGallerySnapshot.swift for how it gets rendered to a PNG outside the app target.
// Split into DesignGalleryFoundations/Attributes/Sidebar/SortFilter/Ordo/Spacing.swift
// so no single file crosses the 500-line project rule; this file only assembles them.
// Fixed 1100pt canvas laid out in two columns so the full-gallery screenshot stays a
// reviewable height instead of one long scroll (spec C3); DesignGallerySnapshot also
// exposes each section as its own crop for per-section review.
import SwiftUI

public struct DesignGallery: View {
    static let canvasWidth: CGFloat = 1100
    static let columnWidth: CGFloat = (canvasWidth - Space.x8 * 3) / 2

    public init() {}

    public var body: some View {
        ScrollView {
            content
        }
        .background(Tok.bg)
        .frame(minWidth: Self.canvasWidth, minHeight: 800)
        .preferredColorScheme(.dark)
    }

    /// The gallery's content without the ScrollView wrapper, so the offline snapshot
    /// renderer (which has no real scroll viewport) can lay it out at full height
    /// directly. See DesignGallerySnapshot.writePNG.
    public var content: some View {
        VStack(alignment: .leading, spacing: Space.x8) {
            GalleryHeader(title: "Kronos Design System")
            HStack(alignment: .top, spacing: Space.x8) {
                VStack(alignment: .leading, spacing: Space.x8) {
                    DesignGalleryTokensSection()
                    DesignGalleryControlsSection()
                    DesignGalleryListSection()
                    DesignGallerySpacingSection()
                    DesignGalleryIconsSection()
                    DesignGalleryIdentitySection()
                }
                .frame(width: Self.columnWidth, alignment: .leading)
                VStack(alignment: .leading, spacing: Space.x8) {
                    DesignGallerySidebarFSection()
                    DesignGalleryNowCardSection()
                    DesignGalleryAccentSection()
                    DesignGallerySidebarSection()
                    DesignGalleryPickersSection()
                    DesignGalleryAttributesSection()
                    DesignGallerySortFilterSection()
                    DesignGalleryViewOptionsSection()
                    DesignGalleryOrdoSection()
                }
                .frame(width: Self.columnWidth, alignment: .leading)
            }
        }
        .padding(Space.x8)
        .background(Tok.bg)
    }
}

/// Shared section chrome so every gallery file uses the same title styles.
struct GalleryHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 28, weight: .bold))
            .foregroundStyle(Tok.textPrimary)
    }
}

struct GallerySectionTitle: View {
    let title: String
    var body: some View {
        Text(title)
            .font(Typo.heading)
            .foregroundStyle(Tok.textPrimary)
            .padding(.bottom, Space.x1)
    }
}

#Preview {
    DesignGallery()
}
