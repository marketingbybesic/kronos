// Kronos/Hotkeys/OptionChordDecider.swift
// The pure decision half of OptionChordMonitor.swift, split out (same reason HotkeyBinding.swift
// was split from HotkeyRegistry.swift: its own header explains the pattern) so a self-test
// script can compile it standalone with a HAND-WRITTEN table, with no live AppKit
// menu/window/app state involved at all.
import AppKit

/// One outcome per match attempt, logged to disk (types/ids only, never typed text or a task
/// title) so a single keypress plus one log read settles whether Kronos ever saw the key.
enum OptionChordOutcome: String {
    case fired, itemMissing = "item-missing", itemDisabled = "item-disabled"
    case stoodDownRecording = "stood-down:recording"
    case stoodDownWrongWindow = "stood-down:wrong-window"
    case pass // not an Option window-scope chord at all: not logged, far too frequent (every keystroke)
}

/// The pure decision: given a keydown's physical key code + modifiers, the live registry
/// bindings, whether the shortcut recorder is capturing, and what kind of window is key — what
/// should happen. No AppKit menu/window lookup here — that needs a live NSMenuItem, done by
/// OptionChordMonitor.swift's `handle(_:)`.
enum OptionChordDecision: Equatable {
    case pass
    case standDown(String) // reason, for the outcome log
    case fire(registryID: String)
}

enum KeyWindowKind: Equatable {
    case kronosMain, other
}

enum OptionChordDecider {
    /// `bindings`: (registryID, binding) pairs for every `.window`-scope entry — the caller
    /// passes `HotkeyRegistry.current(for:)`'s CURRENT value (override-or-default), never a
    /// cached default, so a rebind takes effect on the very next keypress.
    static func decide(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags,
                        bindings: [(id: String, binding: HotkeyBinding)],
                        isRecording: Bool, keyWindowKind: KeyWindowKind,
                        characters: String? = nil) -> OptionChordDecision {
        // Device-independent, minus capsLock/numericPad/function — a user with caps lock on
        // (or using a numeric-pad-adjacent key) still gets the chord; those three flags are
        // not part of any Kronos binding's identity.
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        let optionMatch = bindings.first(where: { $0.binding.option
            && OptionChordDecider.virtualKeyCode(for: $0.binding.key) == keyCode
            && OptionChordDecider.eventFlags(for: $0.binding) == flags })
        // Symbol keys (Cmd-/ and Cmd-\): the printed character moves between layouts ("/" is
        // keycode 44 on US but 27 on Croatian, where keycode 44 prints "-"), and SwiftUI's menu
        // equivalent did not fire Cmd-/ for a user on the HR layout. Match what the layout PRODUCES
        // (charactersIgnoringModifiers), plus backslash's own physical key, which the keymap
        // sheet displays through the live layout (Ž on HR).
        // Brackets (Cmd-] / Cmd-[) are on AltGr on a Croatian layout, so no plain Cmd chord there
        // prints "]" / "[": they match the character where the layout has one, else the physical key
        // position (ANSI codes 30 and 33), the same way backslash does.
        let symbolMatch = bindings.first(where: { b in
            guard !b.binding.option, OptionChordDecider.symbolKeys.contains(b.binding.key),
                  OptionChordDecider.eventFlags(for: b.binding) == flags else { return false }
            let symbol = b.binding.key == "backslash" ? "\\" : b.binding.key
            if characters == symbol { return true }
            return OptionChordDecider.positionalSymbolKeyCodes[b.binding.key] == keyCode
        })
        guard let match = optionMatch ?? symbolMatch else { return .pass }

        if isRecording { return .standDown("recording") }
        guard keyWindowKind == .kronosMain else { return .standDown("wrong-window") }
        return .fire(registryID: match.id)
    }

    /// Window-scope keys that are matched by the character the layout produces (or, for the keys in
    /// `positionalSymbolKeyCodes`, by physical position) rather than by key code alone.
    static let symbolKeys: Set<String> = ["/", "backslash", "[", "]"]

    /// Keys whose printed character is layout-dependent AND that cannot be typed without a modifier
    /// on every layout: matched by physical position as well. Cmd-/ stays character-only.
    static let positionalSymbolKeyCodes: [String: UInt16] = ["backslash": 42, "]": 30, "[": 33]

    /// Letter/digit -> physical key code, INVERTED from `VirtualKeyCodes.letterAndDigitKeys`
    /// (HotkeyBinding.swift) rather than a second table — the same table `SymbolicHotkeyReader`
    /// reads in the other direction.
    static let virtualKeyCodes: [String: UInt16] = Dictionary(
        uniqueKeysWithValues: VirtualKeyCodes.letterAndDigitKeys.map { (keyCode, key) in (key, UInt16(keyCode)) })

    private static func virtualKeyCode(for key: String) -> UInt16? { virtualKeyCodes[key] }

    private static func eventFlags(for b: HotkeyBinding) -> NSEvent.ModifierFlags {
        var m: NSEvent.ModifierFlags = []
        if b.shift { m.insert(.shift) }
        if b.option { m.insert(.option) }
        if b.control { m.insert(.control) }
        if b.command { m.insert(.command) }
        return m
    }
}
