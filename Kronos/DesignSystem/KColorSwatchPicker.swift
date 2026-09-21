// Kronos/DesignSystem/KColorSwatchPicker.swift
// Curated 12-colour palette for project/area identity — the only place colour appears
// in chrome besides KProjectGlyph/KEmojiPicker. No red or red-adjacent hues: no alarm
// colours anywhere. Every swatch is checked by verify-contrast.mjs to be >= 3:1 against
// pure OLED black, since a dot/fill only needs to be perceivable, not read as body text.
import SwiftUI

public enum KProjectPalette {
    /// (name, hex string, colour) — name is used for the accessibility label and by
    /// verify-contrast.mjs to report each swatch by name rather than an anonymous index;
    /// hex is the stored-data form (KAccentPicker/Accent.resolve compare against this,
    /// never against a `Color` value, which has no reliable equality).
    public static let swatches: [(name: String, hex: String, color: Color)] = [
        ("amber",    "F2C94C", Color(hex: 0xF2C94C)),
        ("gold",     "E8B339", Color(hex: 0xE8B339)),
        ("green",    "3FB950", Color(hex: 0x3FB950)),
        ("mint",     "5CE1C4", Color(hex: 0x5CE1C4)),
        ("teal",     "2DD4BF", Color(hex: 0x2DD4BF)),
        ("cyan",     "4CC2FF", Color(hex: 0x4CC2FF)),
        ("blue",     "5B8DEF", Color(hex: 0x5B8DEF)),
        ("indigo",   "8B7CF6", Color(hex: 0x8B7CF6)),
        ("violet",   "A66BFF", Color(hex: 0xA66BFF)),
        ("purple",   "C77DFF", Color(hex: 0xC77DFF)),
        ("orange",   "F2994A", Color(hex: 0xF2994A)),
        ("graphite", "C0C4CC", Color(hex: 0xC0C4CC)),
    ]

    /// The visible name for a swatch's raw internal identifier ("amber" -> "Amber"/"Jantarna"),
    /// in the app's UI language. `swatch.name` itself must stay the lowercase English data key
    /// (stored in ProjectPalettePrefs, matched by verify-contrast.mjs) — only the DISPLAY text
    /// goes through the catalog. A LITERAL `String(localized: "key")` per case, never a
    /// dynamically built key (KPlural.swift documents why: a runtime-built key is never
    /// statically visible, which broke the snapshot harness once already). Falls back to a
    /// capitalised raw name for any swatch added here without a matching case, rather than
    /// showing nothing.
    public static func displayName(for rawName: String) -> String {
        switch rawName {
        case "amber": return String(localized: "accent.swatch.amber")
        case "gold": return String(localized: "accent.swatch.gold")
        case "green": return String(localized: "accent.swatch.green")
        case "mint": return String(localized: "accent.swatch.mint")
        case "teal": return String(localized: "accent.swatch.teal")
        case "cyan": return String(localized: "accent.swatch.cyan")
        case "blue": return String(localized: "accent.swatch.blue")
        case "indigo": return String(localized: "accent.swatch.indigo")
        case "violet": return String(localized: "accent.swatch.violet")
        case "purple": return String(localized: "accent.swatch.purple")
        case "orange": return String(localized: "accent.swatch.orange")
        case "graphite": return String(localized: "accent.swatch.graphite")
        case "lime": return String(localized: "accent.swatch.lime")
        case "yellow": return String(localized: "accent.swatch.yellow")
        case "spring": return String(localized: "accent.swatch.spring")
        case "aqua": return String(localized: "accent.swatch.aqua")
        case "sky": return String(localized: "accent.swatch.sky")
        case "electric": return String(localized: "accent.swatch.electric")
        case "magenta": return String(localized: "accent.swatch.magenta")
        default: return rawName.capitalized
        }
    }

    /// `swatches` reordered (and any custom-replaced) per Settings > Appearance's palette
    /// editor (`ProjectPalettePrefs`) — every picker in the app reads THIS, not `swatches`
    /// directly, so a reorder/replace is visible everywhere immediately. Falls back to
    /// `swatches`' own order with no overrides until the palette is edited.
    public static var orderedSwatches: [(name: String, hex: String, color: Color)] {
        let byName = Dictionary(uniqueKeysWithValues: swatches.map { ($0.name, $0) })
        return ProjectPalettePrefs.slots.compactMap { slot in
            guard let base = byName[slot.baseName] else { return nil }
            let hex = slot.resolvedHex(baseHex: base.hex)
            return (name: base.name, hex: hex, color: hex == base.hex ? base.color : Color(hexString: hex))
        }
    }
}

/// A 6-per-row grid of colour swatches; the selected one gets a 2pt ring per spec §3.3.
/// Usage: KColorSwatchPicker(selected: $projectColor)
public struct KColorSwatchPicker: View {
    @Binding var selected: Color
    private let columns = Array(repeating: GridItem(.flexible(), spacing: Space.x2), count: 6)

    public init(selected: Binding<Color>) {
        self._selected = selected
    }

    public var body: some View {
        LazyVGrid(columns: columns, spacing: Space.x2) {
            ForEach(KProjectPalette.orderedSwatches, id: \.name) { swatch in
                Button {
                    selected = swatch.color
                } label: {
                    Circle()
                        .fill(swatch.color)
                        .frame(width: 20, height: 20)
                        .overlay(
                            Circle()
                                .strokeBorder(Tok.textPrimary, lineWidth: swatch.color == selected ? 2 : 0)
                                .padding(-2)
                        )
                }
                .buttonStyle(.plain)
                .frame(minWidth: Metrics.minHit, minHeight: Metrics.minHit)
                .accessibilityLabel(swatch.name)
                .accessibilityAddTraits(swatch.color == selected ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}
