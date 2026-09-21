// Kronos/Palette/PaletteCommand.swift
// Commands are DATA, not a switch statement: one registry (PaletteCommands.all) is the single
// place to add a command, and it also drives the keymap reference sheet so that screen can
// never drift from what the app actually registers.
import SwiftUI
import KronosCore

/// Declaration order IS render order (`PaletteResults.groups` iterates `allCases`): Commands
/// first, then Go to, then Tasks last — a query must never let task-search results push
/// commands or scopes out of the visible window.
enum PaletteGroup: Int, CaseIterable {
    case create, session, coach, app, view, goTo, task

    var titleKey: String {
        switch self {
        case .create:  return "list.new"
        case .session: return "palette.section.run"
        // Not in the catalog yet ("Coach") — reported, per brief §"every string through the
        // catalog"; never invented into Localizable.xcstrings by this leaf.
        case .coach:   return "palette.section.coach"
        case .app:     return "palette.section.actions"
        case .view:    return "list.display"
        case .goTo:    return "palette.section.navigate"
        case .task:    return "palette.section.tasks"
        }
    }
}

@MainActor
struct PaletteCommand: Identifiable {
    let id: String
    /// Empty when `literalTitle` is used instead (a row named from user data, e.g. a project).
    /// Every value used here must exist in Localizable.xcstrings — a missing key must be
    /// added there, never patched around with a runtime fallback (gate-app's string-key
    /// lint).
    let titleKey: String
    /// Set only for rows whose name comes from user data rather than the string catalog.
    let literalTitle: String?
    let glyph: String
    /// Set only for a Go-to project row: draws the project's own `KProjectGlyph` (icon +
    /// colour) instead of `glyph`'s generic folder symbol, matching list/sidebar identity.
    var projectIcon: String? = nil
    var projectColorHex: String? = nil
    /// Key caps shown via KKeyHint, e.g. ["⌘", "K"]. Empty when the command has no shortcut
    /// (still listed in the palette, just absent from the keymap sheet's rows).
    let shortcut: [String]
    let group: PaletteGroup
    let isAvailable: (AppModel) -> Bool
    let run: (AppModel) -> Void

    init(id: String, titleKey: String = "", literalTitle: String? = nil, glyph: String,
         projectIcon: String? = nil, projectColorHex: String? = nil,
         shortcut: [String] = [], group: PaletteGroup,
         isAvailable: @escaping (AppModel) -> Bool = { _ in true },
         run: @escaping (AppModel) -> Void) {
        self.id = id
        self.titleKey = titleKey
        self.literalTitle = literalTitle
        self.glyph = glyph
        self.projectIcon = projectIcon
        self.projectColorHex = projectColorHex
        self.shortcut = shortcut
        self.group = group
        self.isAvailable = isAvailable
        self.run = run
    }

    var title: String {
        if let literalTitle { return literalTitle }
        return String(localized: String.LocalizationValue(titleKey))
    }

    /// A Go-to project row is prefixed with its area, per spec §3.2. Returned by
    /// `PaletteCommands` when constructing project rows; kept out of `title` itself so
    /// search still matches on the bare project name.
    func withLiteralTitle(_ text: String) -> PaletteCommand {
        PaletteCommand(id: id, titleKey: titleKey, literalTitle: text, glyph: glyph,
                        projectIcon: projectIcon, projectColorHex: projectColorHex,
                        shortcut: shortcut, group: group, isAvailable: isAvailable, run: run)
    }
}
