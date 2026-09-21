// Kronos/DesignSystem/DesignGalleryIconsSection.swift
// Gallery section: every Lucide-style name Icon.swift's map understands, glyph next to
// name, in a grid — so a missing/unmapped glyph (the fallback questionmark.folder) is
// visible at a glance rather than discovered later in a shipped screen.
import SwiftUI

struct DesignGalleryIconsSection: View {
    private let columns = Array(repeating: GridItem(.flexible(), spacing: Space.x3), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            GallerySectionTitle(title: "Icon map — every mapped name (\(Icon.allMappedNames.count))")
            LazyVGrid(columns: columns, spacing: Space.x2) {
                ForEach(Icon.allMappedNames, id: \.self) { name in
                    HStack(spacing: Space.x2) {
                        Icon(name, size: Metrics.iconM).foregroundStyle(Tok.textSecondary)
                        Text(name)
                            .font(Typo.mono)
                            .foregroundStyle(Tok.textTertiary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }
}
