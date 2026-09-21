// Kronos/Hotkeys/HotkeyBinding.swift
// The framework-independent half of HotkeyBinding, split out of HotkeyRegistry.swift so
// scripts/hotkey-accept-selftest.swift can compile it standalone — the same reason
// Kronos/QuickAdd/QuickAddShortcutRepair.swift exists as its own Foundation-only file: the
// class it is called from pulls in AppKit/KeyboardShortcuts and cannot be built that way. The
// SwiftUI/KeyboardShortcuts-specific members (`modifiers`, `keyEquivalent`, `globalShortcut`)
// stay as an extension in HotkeyRegistry.swift, which already imports those frameworks — no
// behaviour change, only which file each member lives in.
import Foundation

/// One key + modifier set, independent of any UI framework. Codable so a user override can
/// live in UserDefaults; Hashable so `HotkeyConflictChecker` can key a dictionary by binding.
public struct HotkeyBinding: Codable, Hashable, Sendable {
    /// Lowercased single character, or a named special key ("space", "return", "escape", …).
    public let key: String
    public let shift: Bool
    public let option: Bool
    public let control: Bool
    public let command: Bool

    public init(_ key: String, shift: Bool = false, option: Bool = false, control: Bool = false, command: Bool = false) {
        self.key = key.lowercased()
        self.shift = shift
        self.option = option
        self.control = control
        self.command = command
    }

    /// Display key caps for `KKeyHint` ("⌃", "⌥", "K"). Order matches macOS convention:
    /// Control, Option, Shift, Command, then the key itself uppercased. `translate` maps a
    /// Carbon virtual key code (no modifiers) to the
    /// character the CURRENT keyboard layout prints there, or `nil`/anything non-printing to
    /// signal "could not translate" — this is the seam a self-test injects a fake translator
    /// through, so the mapping is tested without depending on the test machine's own layout.
    /// Applies ONLY to `Self.layoutDependentKeys` (punctuation
    /// whose printed character genuinely varies by layout); letters/digits are left alone
    /// (measured identical across US and Croatian keyboard layouts).
    public func displayKeys(translate: (UInt16) -> String?) -> [String] {
        var caps: [String] = []
        if control { caps.append("⌃") }
        if option { caps.append("⌥") }
        if shift { caps.append("⇧") }
        if command { caps.append("⌘") }
        caps.append(Self.displayKeyLabel(key: key, translate: translate))
        return caps
    }

    /// One key's own label, factored out so the self-test can hand-table it directly without
    /// building a whole `HotkeyBinding`.
    static func displayKeyLabel(key: String, translate: (UInt16) -> String?) -> String {
        if let vk = Self.layoutDependentKeys[key], let produced = translate(vk),
           let scalar = produced.unicodeScalars.first, produced.unicodeScalars.count == 1,
           CharacterSet.controlCharacters.contains(scalar) == false, !produced.isEmpty {
            return produced.uppercased()
        }
        return Self.displayNames[key] ?? key.uppercased()
    }

    static let displayNames: [String: String] = [
        "space": "Space", "return": "⏎", "escape": "⎋", "delete": "⌫",
        "up": "↑", "down": "↓", "left": "←", "right": "→", "backslash": "\\", "tab": "⇥",
    ]

    /// Named keys this registry stores as a multi-character string but that are really ONE
    /// symbol whose PRINTED CHARACTER depends on the keyboard layout — today only backslash.
    /// Virtual key code from `VirtualKeyCodes.letterAndDigitKeys` (42: "backslash"), inverted.
    /// Shared between `keyEquivalent` (HotkeyRegistry.swift, needs the real character for
    /// SwiftUI) and `displayKeys` (needs it for what to print in Settings/the keymap sheet).
    static let layoutDependentKeys: [String: UInt16] = Dictionary(
        uniqueKeysWithValues: VirtualKeyCodes.letterAndDigitKeys
            .filter { $0.value == "backslash" }
            .map { (keyCode, key) in (key, UInt16(keyCode)) })
}

/// Carbon virtual key codes for letters/digits/space/backslash (Carbon.HIToolbox's kVK_* values,
/// hand-verified against a live plist — see SymbolicHotkeyReader.swift's own comment). Lives
/// here, Foundation-only, so it is the SINGLE table both `SymbolicHotkeyReader` (reads a
/// keyCode -> key string, from macOS's own symbolic-hotkeys plist) and `OptionChordDecider`
/// (reads a key string -> keyCode, to match a real NSEvent by physical key) invert from. It
/// lives outside SymbolicHotkeyReader.swift so a standalone self-test can compile
/// OptionChordDecider without pulling in HotkeyConflictChecker/HotkeyRegistry's
/// AppKit/KeyboardShortcuts dependency chain.
public enum VirtualKeyCodes {
    public static let letterAndDigitKeys: [Int: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
        11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0",
        31: "o", 32: "u", 34: "i", 35: "p", 37: "l", 38: "j", 40: "k", 45: "n", 46: "m",
        49: "space", 42: "backslash",
    ]
}
