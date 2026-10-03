// Kronos/Palette/KeymapCardKeys.swift
// Keys that work inside a card, the palette itself or the inspector's editors. They are fixed
// (not rebindable), so they are not in HotkeyRegistry, and the shortcuts sheet used to omit
// them. Each row names the source file and a fragment of the code that handles the key, so the
// self-test can prove the sheet never lists a key nothing handles.
import Foundation

struct KeymapCardKey: Equatable {
    enum Section: String, CaseIterable { case palette, inspector, pickOne, list }
    let id: String
    /// String catalog key of the action's name.
    let titleKey: String
    /// One cap per element, modifiers first (⌃ ⌥ ⇧ ⌘, then the key).
    let keys: [String]
    let section: Section
    /// Repository-relative file and a fragment that must appear in it.
    let sourceFile: String
    let sourceNeedle: String
}

enum KeymapCardKeys {
    static let all: [KeymapCardKey] = [
        KeymapCardKey(id: "palette.run", titleKey: "keymap.card.palette.run", keys: ["⏎"], section: .palette,
                      sourceFile: "Kronos/Palette/CommandPaletteView.swift", sourceNeedle: "event.keyCode == 36"),
        KeymapCardKey(id: "palette.keepopen", titleKey: "keymap.card.palette.keepopen", keys: ["⌘", "⏎"], section: .palette,
                      sourceFile: "Kronos/Palette/CommandPaletteView.swift", sourceNeedle: "withCommandModifier: event.modifierFlags.contains(.command)"),
        KeymapCardKey(id: "palette.nextgroup", titleKey: "keymap.card.palette.nextgroup", keys: ["⇥"], section: .palette,
                      sourceFile: "Kronos/Palette/CommandPaletteView.swift", sourceNeedle: "event.keyCode == 48"),
        KeymapCardKey(id: "palette.prevgroup", titleKey: "keymap.card.palette.prevgroup", keys: ["⇧", "⇥"], section: .palette,
                      sourceFile: "Kronos/Palette/CommandPaletteView.swift", sourceNeedle: "forward: !event.modifierFlags.contains(.shift)"),
        KeymapCardKey(id: "palette.back", titleKey: "keymap.card.palette.back", keys: ["esc"], section: .palette,
                      sourceFile: "Kronos/Palette/CommandPaletteView.swift", sourceNeedle: "event.keyCode == 53"),

        KeymapCardKey(id: "inspector.complete", titleKey: "keymap.card.inspector.complete", keys: ["⌘", "⏎"], section: .inspector,
                      sourceFile: "Kronos/Detail/InspectorScreen.swift", sourceNeedle: "toggleDone(task)"),
        KeymapCardKey(id: "inspector.back", titleKey: "keymap.card.inspector.back", keys: ["esc"], section: .inspector,
                      sourceFile: "Kronos/Detail/InspectorScreen.swift", sourceNeedle: "kronosFocusListRequested"),
        KeymapCardKey(id: "inspector.stepup", titleKey: "keymap.card.inspector.stepup", keys: ["⌥", "↑"], section: .inspector,
                      sourceFile: "Kronos/Detail/InspectorStepsSection.swift", sourceNeedle: "press.modifiers.contains(.option)"),
        KeymapCardKey(id: "inspector.stepdown", titleKey: "keymap.card.inspector.stepdown", keys: ["⌥", "↓"], section: .inspector,
                      sourceFile: "Kronos/Detail/InspectorStepsSection.swift", sourceNeedle: ".onKeyPress(.downArrow"),
        KeymapCardKey(id: "inspector.addsteps", titleKey: "keymap.card.inspector.addsteps", keys: ["⌘", "⏎"], section: .inspector,
                      sourceFile: "Kronos/Detail/InspectorBreakdownPreview.swift", sourceNeedle: ".keyboardShortcut(.return, modifiers: .command)"),

        KeymapCardKey(id: "pickone.low", titleKey: "keymap.card.pickone.low", keys: ["1"], section: .pickOne,
                      sourceFile: "Kronos/Impuls/ImpulsScreen.swift", sourceNeedle: ".onKeyPress(\"1\")"),
        KeymapCardKey(id: "pickone.mid", titleKey: "keymap.card.pickone.mid", keys: ["2"], section: .pickOne,
                      sourceFile: "Kronos/Impuls/ImpulsScreen.swift", sourceNeedle: ".onKeyPress(\"2\")"),
        KeymapCardKey(id: "pickone.high", titleKey: "keymap.card.pickone.high", keys: ["3"], section: .pickOne,
                      sourceFile: "Kronos/Impuls/ImpulsScreen.swift", sourceNeedle: ".onKeyPress(\"3\")"),
        KeymapCardKey(id: "pickone.start", titleKey: "keymap.card.pickone.start", keys: ["⏎"], section: .pickOne,
                      sourceFile: "Kronos/Impuls/ImpulsScreen.swift", sourceNeedle: ".onKeyPress(.return) { start()"),
        KeymapCardKey(id: "pickone.another", titleKey: "keymap.card.pickone.another", keys: ["→"], section: .pickOne,
                      sourceFile: "Kronos/Impuls/ImpulsScreen.swift", sourceNeedle: ".onKeyPress(.rightArrow)"),
        KeymapCardKey(id: "pickone.close", titleKey: "keymap.card.pickone.close", keys: ["esc"], section: .pickOne,
                      sourceFile: "Kronos/Impuls/ImpulsScreen.swift", sourceNeedle: ".onKeyPress(.escape) { close()"),

        KeymapCardKey(id: "list.selectall", titleKey: "keymap.card.list.selectall", keys: ["⌘", "A"], section: .list,
                      sourceFile: "Kronos/List/TaskListScreen+Bulk.swift", sourceNeedle: "func handleSelectAll"),
        KeymapCardKey(id: "list.clearselection", titleKey: "keymap.card.list.clearselection", keys: ["esc"], section: .list,
                      sourceFile: "Kronos/List/TaskListScreen+Bulk.swift", sourceNeedle: "func handleEscape"),
    ]

    static func keys(in section: KeymapCardKey.Section) -> [KeymapCardKey] { all.filter { $0.section == section } }

    /// String catalog key of a section's title.
    static func titleKey(_ section: KeymapCardKey.Section) -> String {
        switch section {
        case .palette: return "keymap.card.section.palette"
        case .inspector: return "keymap.card.section.inspector"
        case .pickOne: return "keymap.card.section.pickone"
        case .list: return "keymap.card.section.list"
        }
    }
}
