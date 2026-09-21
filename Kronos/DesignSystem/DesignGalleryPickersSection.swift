// Kronos/DesignSystem/DesignGalleryPickersSection.swift
// Gallery section: project identity — KProjectGlyph + KColorSwatchPicker + KEmojiPicker.
// This is one of the only two places colour appears anywhere in the app (the other is
// a project's own dot/glyph elsewhere) — everything else in the UI is monochrome.
import SwiftUI

struct DesignGalleryPickersSection: View {
    @State private var projectColor: Color = KProjectPalette.swatches[6].color   // blue
    @State private var projectEmoji: String = "🌵"
    @State private var accentHex: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x4) {
            GallerySectionTitle(title: "Project identity — colour + emoji")
            HStack(alignment: .top, spacing: Space.x6) {
                VStack(alignment: .leading, spacing: Space.x2) {
                    Text("KProjectGlyph").font(Typo.meta).foregroundStyle(Tok.textTertiary)
                    HStack(spacing: Space.x3) {
                        KProjectGlyph(color: projectColor, emoji: projectEmoji, size: 28)
                        KProjectGlyph(color: KProjectPalette.swatches[2].color, size: 28)   // no emoji -> dot fallback
                        Text("Acme").font(Typo.row).foregroundStyle(Tok.textPrimary)
                    }
                }
                VStack(alignment: .leading, spacing: Space.x2) {
                    Text("KColorSwatchPicker").font(Typo.meta).foregroundStyle(Tok.textTertiary)
                    KColorSwatchPicker(selected: $projectColor).frame(width: 220)
                }
            }
            VStack(alignment: .leading, spacing: Space.x2) {
                Text("KEmojiPicker").font(Typo.meta).foregroundStyle(Tok.textTertiary)
                KEmojiPicker(selected: $projectEmoji).frame(width: 320)
            }
            // KAccentPicker is a SEPARATE personalisation axis (feature H, see Accent.swift)
            // from the project colour above — same 12 swatches, plus a White default tile.
            VStack(alignment: .leading, spacing: Space.x2) {
                Text("KAccentPicker").font(Typo.meta).foregroundStyle(Tok.textTertiary)
                KAccentPicker(selectionHex: $accentHex).frame(width: 260)
            }
        }
    }
}
