// Kronos/MenuBar/MenuBarMenuSpec.swift
// What the status item's right-click menu contains and in what order, as plain data so a
// hand-written table can judge it (scripts/menubar-hit-selftest.swift compiles this exact file).
// Commands that cannot run right now stay in the menu, disabled (menu bar rule: disable, never hide).
import Foundation

enum MenuBarMenuSpec {
    enum Item: Equatable {
        case open, quickAdd, pickOne, completeCurrent, quietLines, settings, quit, separator
    }

    struct Row: Equatable {
        let item: Item
        let enabled: Bool
        let checked: Bool
    }

    static func rows(hasFocus: Bool, quietLinesOn: Bool) -> [Row] {
        func row(_ item: Item, enabled: Bool = true, checked: Bool = false) -> Row { Row(item: item, enabled: enabled, checked: checked) }
        return [
            row(.open), row(.quickAdd), row(.pickOne), row(.completeCurrent, enabled: hasFocus),
            row(.separator),
            row(.quietLines, checked: quietLinesOn), row(.settings),
            row(.separator),
            row(.quit),
        ]
    }
}
