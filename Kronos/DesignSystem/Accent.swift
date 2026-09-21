// Kronos/DesignSystem/Accent.swift
// User-chosen accent colour — a SEPARATE personalisation axis from project colour and from
// ChromaMode. Default is white (today's look, unchanged). Used ONLY by: primary button fill,
// selection bar (list/sidebar/palette rows), keyboard focus ring, toggle on-state, the Now
// card's Complete ring, the selected segment marker. Text never takes the accent. Calm mode
// forces white regardless of the stored hex, so the distraction-free mode never grows a hue
// back from personalisation (chroma gate G4).
//
// The accent axis has its OWN swatch set (`AccentPalette`, below), distinct from
// `KProjectPalette` (project/area identity, unaffected), plus a free-form `ColorPicker` hex.
// `resolve` therefore accepts ANY well-formed 6-hex-digit string, not only a swatch match: a
// custom colour would otherwise silently fall back to white. Every `AccentPalette` swatch is
// still hand-checked against the same floors `verify-contrast.mjs` enforces for the project
// palette (>= 3:1 bar/ring, >= 4.5:1 best-of-black/white label) and is never red/red-adjacent
// (hue 20-340°) — see the swatch table's own comment for the numbers. A free-form colour typed
// or dragged into the native picker is NOT gated (there is no way to gate an open colour
// space); an unreadable choice is the user's own call, same as any OS accent-colour picker.
import SwiftUI

/// The accent axis's own swatch set — neon, not the calmer project-identity palette.
/// (name, hex) only: `Accent.resolve` needs no `Color` value since it builds one from the hex,
/// same as it now does for a custom colour. Each hue was checked by hand against the same
/// formulas `verify-contrast.mjs` uses (relative luminance vs pure black):
///   name        hex      bar/ring   label(best)   hue
///   lime        9FFF3D    16.85:1     16.85:1      90°
///   spring      33FFB2    16.09:1     16.09:1     157°
///   aqua        1FFFF0    16.62:1     16.62:1     176°
///   sky         2FD8FF    12.39:1     12.39:1     191°
///   electric    5B5BFF     4.39:1      4.79:1     240°
///   violet      9D4CFF     4.91:1      4.91:1     267°
///   magenta     FF2FD8     6.65:1      6.65:1     311°
///   yellow      E9FF3D    18.84:1     18.84:1      67°
/// All clear the 3:1 bar/ring and 4.5:1 label floors with margin; none fall in the 20-340°
/// forbidden red band.
public enum AccentPalette {
    public static let swatches: [(name: String, hex: String)] = [
        ("lime",     "9FFF3D"),
        ("yellow",   "E9FF3D"),
        ("spring",   "33FFB2"),
        ("aqua",     "1FFFF0"),
        ("sky",      "2FD8FF"),
        ("electric", "5B5BFF"),
        ("violet",   "9D4CFF"),
        ("magenta",  "FF2FD8"),
    ]
}

private struct AccentKey: EnvironmentKey {
    static let defaultValue: Color = Tok.textPrimary
}

public extension EnvironmentValues {
    /// The resolved accent colour for this screen. Screens set it once at the root via
    /// `.environment(\.kAccent, Accent.resolve(settings.accentHex, mode: chromaMode))` and
    /// every component below reads it — never re-resolve per component.
    var kAccent: Color {
        get { self[AccentKey.self] }
        set { self[AccentKey.self] = newValue }
    }
}

public enum Accent {
    /// nil hex (no personalisation chosen) or Calm mode (distraction-free — never grows a
    /// hue back) both resolve to white, matching `Tok.textPrimary` exactly so the un-set
    /// state is pixel-identical to before this feature existed.
    /// A hex matching a known swatch (project palette OR the accent's own `AccentPalette`)
    /// resolves to that swatch's exact colour value; any OTHER well-formed "#RRGGBB"/"RRGGBB"
    /// is a custom colour from the native `ColorPicker` and is parsed directly — a prior
    /// version bypassed the contrast oracle here (a custom colour silently fell back to white,
    /// which is why "custom colour" looked like it did nothing). An unparseable string still
    /// falls back to white rather than `Color(hexString:)`'s own tertiary-text fallback, which
    /// would be a hue-less grey masquerading as "no accent chosen".
    /// Not `public`: `ChromaMode` itself is internal (Kronos/DesignSystem is a source folder
    /// in the single Kronos target, not a separate module, and ChromaMode.swift declares it
    /// without `public`; see Chroma.tint in ChromaMode.swift for the same constraint). Every
    /// call site lives in this same target, so this is not a real visibility restriction, only
    /// what the compiler requires.
    static func resolve(_ hex: String?, mode: ChromaMode) -> Color {
        guard mode != .calm, let hex else { return Tok.textPrimary }
        let normalizedHex = normalized(hex)
        if let swatch = KProjectPalette.swatches.first(where: { $0.hex.caseInsensitiveCompare(normalizedHex) == .orderedSame }) {
            return swatch.color
        }
        if let match = AccentPalette.swatches.first(where: { $0.hex.caseInsensitiveCompare(normalizedHex) == .orderedSame }) {
            return Color(hexString: match.hex)
        }
        guard normalizedHex.count == 6, UInt32(normalizedHex, radix: 16) != nil else { return Tok.textPrimary }
        return Color(hexString: normalizedHex)
    }

    private static func normalized(_ hex: String) -> String {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        return s
    }

    /// The readable label colour on a fill fo this accent: black on light swatches, white on
    /// dark ones. Every palette swatch already clears >= 4.5:1 against ONE of the two
    /// (verify-contrast.mjs asserts it), so this is a simple luminance split, not a guess.
    public static func onFill(_ accent: Color) -> Color {
        accent.resolvedLuminance > 0.5 ? .black : .white
    }
}

private extension Color {
    /// Relative (WCAG) luminance of the resolved sRGB colour, used only to pick a readable
    /// label — not a contrast proof (verify-contrast.mjs owns the real numbers per swatch).
    var resolvedLuminance: Double {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(Double(c.redComponent)) + 0.7152 * lin(Double(c.greenComponent)) + 0.0722 * lin(Double(c.blueComponent))
    }
}
