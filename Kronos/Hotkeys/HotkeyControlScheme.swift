// Kronos/Hotkeys/HotkeyControlScheme.swift
// The "Control scheme" preset: for a Mac set up Control-first, every rebindable window shortcut
// that uses Command moves to the same key with Control in place of Command (⌘K → ⌃K,
// ⌥⌘F → ⌃⌥F), wherever that chord is free. A chord that is taken (a macOS shortcut that is on,
// another Kronos shortcut in any scope, a key the scheme never uses) keeps its Command form, so
// the preset can never create a clash. Undo and Redo stay on ⌘Z / ⇧⌘Z: they are the standard
// Edit menu keys and ⌃Z belongs to the terminal. Entries that already use Control are left
// alone. Foundation only, so scripts/hotkey-accept-selftest.swift compiles THIS file against a
// hand-written table; HotkeyRegistry applies the result as ordinary user overrides, so
// "Reset to defaults" undoes it.
import Foundation

enum HotkeyControlScheme {
    /// One registry entry as the preset sees it.
    struct Input: Equatable {
        let id: String
        let isWindowScope: Bool
        let isRebindable: Bool
        /// The binding in effect now (override or default).
        let binding: HotkeyBinding
    }

    /// Entries the preset never moves.
    static let keepsCommand: Set<String> = ["window.undo", "window.redo"]

    /// Chords the preset never assigns: ⌃C and ⌃Z interrupt and suspend in every terminal.
    static let neverAssigned: Set<HotkeyBinding> = [
        HotkeyBinding("c", control: true),
        HotkeyBinding("z", control: true),
    ]

    /// The Control form of a Command chord: same key, Shift and Option kept, Command replaced
    /// by Control. Nil when the binding has no Command or already has Control.
    static func controlForm(of b: HotkeyBinding) -> HotkeyBinding? {
        guard b.command, !b.control else { return nil }
        return HotkeyBinding(b.key, shift: b.shift, option: b.option, control: true, command: false)
    }

    /// New bindings by entry id (only the entries that move). `taken` = chords the system holds
    /// right now (enabled macOS symbolic hotkeys) plus any the caller wants kept free.
    static func preset(_ entries: [Input], taken: Set<HotkeyBinding>) -> [String: HotkeyBinding] {
        var occupied = Set(entries.map(\.binding)).union(taken).union(neverAssigned)
        var moved: [String: HotkeyBinding] = [:]
        for e in entries where e.isWindowScope && e.isRebindable && !keepsCommand.contains(e.id) {
            guard let target = controlForm(of: e.binding), !occupied.contains(target) else { continue }
            moved[e.id] = target
            occupied.insert(target)
            occupied.remove(e.binding)
        }
        return moved
    }

    /// Effective bindings after applying `moved` (for the "no two entries on one chord" check).
    static func applied(_ entries: [Input], _ moved: [String: HotkeyBinding]) -> [(id: String, binding: HotkeyBinding)] {
        entries.map { ($0.id, moved[$0.id] ?? $0.binding) }
    }
}
