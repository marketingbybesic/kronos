// Kronos/Shared/SelectionHue+Color.swift
// Maps the pure `SelectionHue` decision (KronosCore) to a concrete colour, and carries the one
// place that says which colour mode is "neutral". Focus is the app's monochrome mode ("colour only
// on the task you are doing"): its selection, row line and view-header mark are white, the same
// neutral treatment the white accent gets. Full mode lets the project colour / accent through.
import SwiftUI
import KronosCore

extension SelectionHue {
    /// `accent` = the user's resolved accent (`\.kAccent`). `.white` is `Tok.textPrimary`, the colour
    /// `KSelection`/`KRing` already treat as "the white case".
    func color(accent: Color) -> Color {
        switch self {
        case .project(let hex): return Color(hexString: hex)
        case .accent: return accent
        case .white: return Tok.textPrimary
        }
    }
}

extension ChromaMode {
    /// Monochrome mode: selection and header marks carry no hue.
    var isNeutralSelection: Bool { self == .focus }
}

extension ListScope {
    /// The view's own mark: the sidebar icon of a fixed scope. Project views draw the project's
    /// icon instead; areas and saved views take the generic folder mark.
    var leadingIcon: String {
        switch self {
        case .inbox: return "inbox"
        case .today: return "sun"
        case .next7: return "calendar-days"
        case .waiting: return "hourglass"
        case .someday: return "sparkles"   // "archive" maps to an SF Symbol that does not exist on this OS
        case .all: return "list-ordered"
        case .project, .area, .savedView: return "folder"
        }
    }
}
