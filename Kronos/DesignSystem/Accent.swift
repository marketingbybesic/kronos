// Kronos/DesignSystem/Accent.swift
// User-chosen accent colour — a SEPARATE personalisation axis from project colour and from
// ChromaMode. Default is white. Used ONLY by: primary button fill, selection bar (list/sidebar/
// palette rows), keyboard focus ring, toggle on-state, the Now card's Complete ring, the selected
// segment marker, the done checkbox and the undo pill's countdown. Text never takes the accent.
// Focus colour mode resolves every accent to white: the calm mode never grows a hue back from
// personalisation, so in Focus the only colour on screen is what the colour carriers allow.
//
// The accent axis has its OWN swatch set (`AccentPalette`, below), distinct from
// `KProjectPalette` (project/area identity, unaffected), plus a free-form `ColorPicker` hex.
// `resolve` therefore accepts ANY well-formed 6-hex-digit string, not only a swatch match: a
// custom colour would otherwise silently fall back to white. Every `AccentPalette` swatch is
// checked by verify-contrast.mjs and scripts/design/verify-ring-contrast.mjs: >= 3:1 as a bar,
// >= 3:1 as a ring at the opacity it is drawn at, >= 4.5:1 for the label `onFill` picks, and
// never in the red band (hue below 20° or above 340°). A free-form colour typed or dragged into
// the native picker cannot be gated as a choice, so the components protect it instead: the ring
// is raised to 3:1 (`KRing.opacity(for:)`) and the label is whichever of black/white reads best.
import SwiftUI

/// The accent axis's own swatch set — neon, not the calmer project-identity palette.
/// (name, hex) only: `Accent.resolve` builds the colour from the hex, same as for a custom colour.
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
    /// Focus mode, or no personalisation chosen (nil hex), resolves to white — `Tok.textPrimary`
    /// itself, so every component that keeps a neutral look for white (`KRing`, `KSelection`)
    /// recognises it.
    /// In Full mode a hex matching a known swatch (project palette OR the accent's own
    /// `AccentPalette`) resolves to that swatch's exact colour value; any OTHER well-formed
    /// "#RRGGBB"/"RRGGBB" is a custom colour from the native `ColorPicker` and is parsed directly
    /// (a prior version bypassed it and a custom colour silently fell back to white). An
    /// unparseable string falls back to white rather than `Color(hexString:)`'s own tertiary-text
    /// fallback, which would be a hue-less grey masquerading as "no accent chosen".
    /// Not `public`: `ChromaMode` itself is internal (Kronos/DesignSystem is a source folder in
    /// the single Kronos target, not a separate module). Every call site lives in this target.
    static func resolve(_ hex: String?, mode: ChromaMode) -> Color {
        guard mode == .full, let hex else { return Tok.textPrimary }
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

    /// The readable label colour on a fill of this accent: black or white, whichever has the
    /// higher WCAG contrast on it. (A plain "luminance above 0.5" split put white labels on
    /// mid-tone fills such as #B483FF, at 2.75:1.)
    public static func onFill(_ accent: Color) -> Color {
        prefersBlackLabel(luminance: KColorMath.luminance(KColorMath.srgb(accent))) ? .black : .white
    }

    /// True when black text reads better than white on a fill of this relative luminance.
    static func prefersBlackLabel(luminance: Double) -> Bool {
        KColorMath.contrast(luminance, 0) >= KColorMath.contrast(luminance, 1)
    }
}
