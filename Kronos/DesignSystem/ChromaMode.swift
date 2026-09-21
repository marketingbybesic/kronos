// Colour modes. A frozen contract file: the ONE place that decides whether user colour is
// shown. Screens pass the mode down with
// `.environment(\.chromaMode, model.chromaMode)` and call `Chroma.tint`; they never branch on the
// mode themselves, so Calm cannot leak hue from a forgotten screen.
import SwiftUI

enum ChromaMode: String, CaseIterable, Codable, Sendable {
    /// Monochrome everywhere; hue only on the task being worked on. Default.
    case focus
    /// Every project shows the colour the user chose.
    case full
    /// Distraction free: no hue anywhere.
    case calm
}

private struct ChromaModeKey: EnvironmentKey {
    static let defaultValue: ChromaMode = .focus
}

extension EnvironmentValues {
    var chromaMode: ChromaMode {
        get { self[ChromaModeKey.self] }
        set { self[ChromaModeKey.self] = newValue }
    }
}

/// Which named surface a glyph's hue is riding on (feature I "colour carriers", Settings >
/// Appearance). `.other` is every glyph not one of the four checkboxes (list rows that are not
/// the focus row, chips, gallery samples, pickers) and is always allowed — the carrier toggles
/// only ever gate the four named surfaces, never chrome in general.
/// `public`: `KProjectGlyph.init(carrier:)` is a public initializer, and a public declaration's
/// parameter types must be at least as visible as it is (unlike `ChromaMode` itself, which stays
/// non-public since nothing public takes it directly — see Accent.swift's own note on that).
public enum ChromaCarrier {
    case rowGlyph, nowCard, sidebarProject, menuBarTitle, other
}

enum Chroma {
    /// The colour a project glyph / dot is drawn in. `isFocus` = this element belongs to the
    /// focus task (its row, its project's sidebar row, the Now card, the menu-bar Ordo).
    /// `carrier` + `carriers` gate Full/Focus's hue further: even when the mode would show
    /// colour, an OFF carrier still forces neutral for that surface (Calm always wins either way).
    static func tint(_ projectColor: Color, mode: ChromaMode, isFocus: Bool,
                      carrier: ChromaCarrier = .other, carriers: ColourCarriers = AppearancePrefs.colourCarriers) -> Color {
        switch mode {
        case .full: return projectColor
        // The carrier toggles are "what carries colour in FOCUS mode": Full always shows the
        // user's colours, Calm never does.
        case .focus: return (isFocus && carriers.allows(carrier)) ? projectColor : Tok.textSecondary
        case .calm: return Tok.textSecondary
        }
    }
}
