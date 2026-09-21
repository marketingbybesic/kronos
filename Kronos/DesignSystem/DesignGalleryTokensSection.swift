// Kronos/DesignSystem/DesignGalleryTokensSection.swift
// Gallery section: color tokens + typography scale. Fully monochrome — the only colour
// anywhere in the app is user DATA (see DesignGalleryPickersSection).
import SwiftUI

struct DesignGalleryTokensSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Space.x8) {
            colorSection
            typeSection
        }
    }

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            GallerySectionTitle(title: "Color tokens")
            swatchRow([
                ("textPrimary", Tok.textPrimary), ("textSecondary", Tok.textSecondary),
                ("textTertiary", Tok.textTertiary), ("textDisabled", Tok.textDisabled),
            ])
            swatchRow([
                ("focusRing", Tok.focusRing), ("hairline", Tok.hairline),
                ("borderControl", Tok.borderControl), ("borderStrong", Tok.borderStrong),
            ])
            swatchRow([
                ("borderActive", Tok.borderActive), ("hoverFill", Tok.hoverFill),
                ("selectedFill", Tok.selectedFill), ("overlay", Tok.overlay),
            ])
        }
    }

    private func swatchRow(_ items: [(String, Color)]) -> some View {
        HStack(spacing: Space.x4) {
            ForEach(items, id: \.0) { name, color in
                VStack(spacing: Space.x1) {
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill(color)
                        .frame(width: 64, height: 40)
                        .kBorder(Tok.hairline, radius: Radius.control)
                    Text(name).font(Typo.mono).foregroundStyle(Tok.textTertiary)
                }
            }
        }
    }

    private var typeSection: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            GallerySectionTitle(title: "Typography")
            Text("Title 20/semibold").font(Typo.title).foregroundStyle(Tok.textPrimary)
            Text("Heading 15/semibold").font(Typo.heading).foregroundStyle(Tok.textPrimary)
            Text("Row 13/regular").font(Typo.row).foregroundStyle(Tok.textPrimary)
            Text("Meta 11/regular").font(Typo.meta).foregroundStyle(Tok.textTertiary)
            Text("SECTION HEADER 11/semibold").font(Typo.sectionHdr).foregroundStyle(Tok.textTertiary)
        }
    }
}
