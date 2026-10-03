// Kronos/Triage/TriageKeyGrammar.swift
// The single-key grammar of the sort cards. It IS the list's grammar (ListKeyGrammar.swift: T today,
// ⇧T tomorrow, D date, P project, H snooze, 0-4 priority, S/M/L effort, B break down, W waiting,
// Y someday, F pin as focus), read from the same registry ids, so a rebound key moves in both
// places and the old letter goes dead in both. This file only adds what a card has and the list
// does not: Space (done) and ⌫ (delete) by key code, the contexts below, and three card-only keys:
// E types the first move, N clears the deadline, R asks the AI again.
// Foundation only, so a self-test can compile THIS file with ListKeyGrammar.swift and
// HotkeyBinding.swift against a hand-written table.
import Foundation

enum TriageEffortKey: Equatable, Sendable { case small, medium, large }

enum TriageKeyAction: Equatable, Sendable {
    case planToday, planTomorrow, snooze, pickDue, pickProject, focusPin
    case priority(Int)
    case effort(TriageEffortKey)
    case breakDown, waiting, someday, delete, done
    /// Card only.
    case editFirstMove, clearDue, refresh
}

/// Which keys a card answers. Sort is the full grammar; Sweep keeps its five decisions (Return
/// keeps, T, Y, ⌫, Space); Review's open fields take only the field keys.
enum TriageKeyContext: Equatable, Sendable { case sort, sweep, reviewEdit }

enum TriageKeyGrammar {
    /// The card action for a list action. The list's "show all subtasks" key has no card meaning.
    static func card(_ action: ListKeyAction) -> TriageKeyAction? {
        switch action {
        case .planToday: return .planToday
        case .planTomorrow: return .planTomorrow
        case .pickDue: return .pickDue
        case .pickProject: return .pickProject
        case .snooze: return .snooze
        case .focusPin: return .focusPin
        case .priority(let level): return .priority(level)
        case .effort(let size):
            switch size {
            case .small: return .effort(.small)
            case .medium: return .effort(.medium)
            case .large: return .effort(.large)
            }
        case .breakDown: return .breakDown
        case .waiting: return .waiting
        case .someday: return .someday
        case .expandAll: return nil
        }
    }

    /// The registry id whose binding names a card action in the legend (nil for the fixed keys).
    static func registryID(for action: TriageKeyAction) -> String? {
        ListKeyGrammar.rebindable.first { card($0.action) == action }?.id
    }

    /// Keys of the card that the list does not have.
    static let cardOnly: [(key: String, action: TriageKeyAction)] = [
        ("e", .editFirstMove), ("n", .clearDue), ("r", .refresh),
    ]

    static func allows(_ action: TriageKeyAction, in context: TriageKeyContext) -> Bool {
        switch context {
        case .sort: return true
        case .sweep:
            switch action {
            case .planToday, .someday, .delete, .done: return true
            default: return false
            }
        case .reviewEdit:
            switch action {
            case .priority, .effort, .pickDue, .pickProject: return true
            default: return false
            }
        }
    }

    /// The action a key press means on this card, or nil (the card then lets the key fall
    /// through). `characters` is what the key produced ignoring modifiers; Shift is read from
    /// the flag, never from the letter's case, so Caps Lock does not turn T into ⇧T. A press
    /// with ⌘, ⌥ or ⌃ is never a grammar key. Space and the delete keys come by key code.
    /// `bindings` answers the CURRENT binding of a registry id.
    static func action(characters: String, keyCode: UInt16, shift: Bool, command: Bool = false,
                       option: Bool = false, control: Bool = false, context: TriageKeyContext = .sort,
                       bindings: (String) -> HotkeyBinding?) -> TriageKeyAction? {
        guard !command, !option, !control else { return nil }
        guard let found = lookup(characters: characters, keyCode: keyCode, shift: shift, bindings: bindings),
              allows(found, in: context) else { return nil }
        return found
    }

    private static func lookup(characters: String, keyCode: UInt16, shift: Bool,
                               bindings: (String) -> HotkeyBinding?) -> TriageKeyAction? {
        switch keyCode {
        case 49: return .done                  // Space
        case 51, 117: return .delete           // Delete, forward delete
        default: break
        }
        guard characters.count == 1 else { return nil }
        if characters == " " { return .done }
        var table: [String: HotkeyBinding] = [:]
        for (id, _) in ListKeyGrammar.rebindable { if let b = bindings(id) { table[id] = b } }
        if let listed = ListKeyGrammar.action(characters: characters, shift: shift, bindings: table),
           let mapped = card(listed) { return mapped }
        guard !shift else { return nil }
        let key = characters.lowercased()
        return cardOnly.first { $0.key == key }?.action
    }

    /// The key caps that name an action in a legend: the CURRENT binding, so a rebind shows.
    static func caps(for action: TriageKeyAction, bindings: (String) -> HotkeyBinding?) -> [String] {
        switch action {
        case .priority: return ["0", "–", "4"]
        case .delete: return ["⌫"]
        case .done: return ["Space"]
        case .editFirstMove: return ["E"]
        case .clearDue: return ["N"]
        case .refresh: return ["R"]
        default:
            guard let id = registryID(for: action), let b = bindings(id) else { return [] }
            return (b.shift ? ["⇧"] : []) + [b.key.uppercased()]
        }
    }
}
