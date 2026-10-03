// Kronos/List/ListKeyGrammar.swift
// The list's single-key grammar: which action a plain key press means, read from the CURRENT
// registry bindings (HotkeyRegistry), so a rebound key moves with its binding and the old letter
// goes dead. One grammar for the list and for triage cards:
//   T today · ⇧T tomorrow · D date · P project · H snooze · 0-4 priority · S/M/L effort ·
//   B break down · W waiting · Y someday · F pin as focus · E show all subtasks
// (Space complete, ⌫ delete, ⏎ open and the arrows are named keys, handled by the list itself.)
// Foundation only, so scripts/hotkey-accept-selftest.swift compiles THIS file with
// HotkeyBinding.swift against a hand-written table.
import Foundation

enum ListEffortKey: Equatable, Sendable { case small, medium, large }

enum ListKeyAction: Equatable, Sendable {
    case planToday, planTomorrow, pickDue, pickProject, snooze, focusPin, expandAll
    case priority(Int)
    case effort(ListEffortKey)
    case breakDown, waiting, someday
}

enum ListKeyGrammar {
    /// Registry ids of the rebindable letter keys, in legend order, with what each means.
    static let rebindable: [(id: String, action: ListKeyAction)] = [
        ("list.plan.today", .planToday),
        ("list.plan.tomorrow", .planTomorrow),
        ("list.due", .pickDue),
        ("list.project", .pickProject),
        ("list.snooze", .snooze),
        ("list.effort.small", .effort(.small)),
        ("list.effort.medium", .effort(.medium)),
        ("list.effort.large", .effort(.large)),
        ("list.breakdown", .breakDown),
        ("list.waiting", .waiting),
        ("list.someday", .someday),
        ("list.focuspin", .focusPin),
        ("list.expandall", .expandAll),
    ]

    /// Fixed priority keys. "o" too: a zero reads as the letter in the legend.
    static let priorityKeys: [Character: Int] = ["0": 0, "o": 0, "1": 1, "2": 2, "3": 3, "4": 4]

    /// The action a key press means, or nil (the list then ignores the key). `characters` is
    /// what the key produced (`KeyPress.characters`); the modifier flags come from the press.
    /// Shift is read from the flag, never from the letter's case, so Caps Lock does not turn
    /// T into ⇧T. A press with ⌘, ⌥ or ⌃ is never a grammar key (those are menu chords).
    static func action(characters: String, shift: Bool, command: Bool = false, option: Bool = false,
                       control: Bool = false, bindings: [String: HotkeyBinding]) -> ListKeyAction? {
        guard !command, !option, !control, characters.count == 1 else { return nil }
        let key = characters.lowercased()
        if !shift, let ch = key.first, let level = priorityKeys[ch] { return .priority(level) }
        for (id, action) in rebindable {
            guard let b = bindings[id], !b.command, !b.option, !b.control else { continue }
            if b.key == key && b.shift == shift { return action }
        }
        return nil
    }

    /// Every character the list must claim for the grammar (both cases of each bound letter),
    /// so `.onKeyPress(characters:)` sees the key at all.
    static func claimedCharacters(bindings: [String: HotkeyBinding]) -> String {
        let letters = rebindable.compactMap { bindings[$0.id]?.key }.filter { $0.count == 1 }.joined()
        return String(priorityKeys.keys.sorted()) + letters + letters.uppercased()
    }
}
