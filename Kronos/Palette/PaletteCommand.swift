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
    case bulk, selected, create, session, coach, app, view, goTo, task

    var titleKey: String {
        switch self {
        case .bulk:    return "palette.bulk.section"   // only offered while 2+ rows are selected
        case .selected: return "palette.section.thistask"   // acts on the task in the inspector
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
    /// The `HotkeyRegistry` entry whose binding this row advertises. The caps are read from the
    /// registry every time they are drawn, so a rebind or a keyboard layout switch shows at once;
    /// no row carries a literal key of its own. Nil when the command has no shortcut.
    let registryID: String?
    /// Catalog key of a small qualifier shown before the caps ("Due date" on "Tomorrow"), and
    /// matched when searching, so a row named only "Tomorrow" is not ambiguous.
    let detailKey: String?
    /// True for a command whose second step happens inside the palette ("Move to…"): running it
    /// must not close the card.
    let keepsOpen: Bool
    let group: PaletteGroup
    let isAvailable: (AppModel) -> Bool
    let run: (AppModel) -> Void

    init(id: String, titleKey: String = "", literalTitle: String? = nil, glyph: String,
         projectIcon: String? = nil, projectColorHex: String? = nil,
         registryID: String? = nil, detailKey: String? = nil, keepsOpen: Bool = false,
         group: PaletteGroup,
         isAvailable: @escaping (AppModel) -> Bool = { _ in true },
         run: @escaping (AppModel) -> Void) {
        self.id = id
        self.titleKey = titleKey
        self.literalTitle = literalTitle
        self.glyph = glyph
        self.projectIcon = projectIcon
        self.projectColorHex = projectColorHex
        self.registryID = registryID
        self.detailKey = detailKey
        self.keepsOpen = keepsOpen
        self.group = group
        self.isAvailable = isAvailable
        self.run = run
    }

    var title: String {
        if let literalTitle { return literalTitle }
        return String(localized: String.LocalizationValue(titleKey))
    }

    var detail: String? {
        detailKey.map { String(localized: String.LocalizationValue($0)) }
    }

    /// Key caps for the row, from the live registry binding (layout aware). Empty without one.
    var shortcut: [String] {
        guard let registryID, let binding = HotkeyRegistry.current(for: registryID) else { return [] }
        return binding.displayKeys
    }

    /// Words matched besides the title: the qualifier, the section name and the synonyms.
    var searchFields: [String] {
        [title] + (detail.map { [$0] } ?? []) + [group.titleKey] + PaletteSynonyms.aliases(for: id)
    }
}
