// Kronos/Hotkeys/SymbolicHotkeyReader.swift
// Reads the user's own macOS symbolic-hotkey overrides (Spotlight, input sources, Mission
// Control, screenshots, …) from `com.apple.symbolichotkeys`, so the conflict checker can name
// a real clash instead of assuming everyone kept Apple's factory defaults. ENABLED entries
// only — a symbolic hotkey turned off in System Settings is not a live conflict.
import AppKit

@MainActor
enum SymbolicHotkeyReader {
    /// Well-known symbolic-hotkey ids -> a human description, restricted to the ones a Kronos
    /// global default could plausibly land on (quick-entry-style single letter/space + a
    /// modifier combo). Full id space is much larger; unmapped ids are simply skipped.
    private static let knownIDs: [Int: String] = [
        64: "Spotlight search",
        65: "Spotlight Finder search window",
        60: "Select the previous input source",
        61: "Select next source in Input Menu",
        32: "Mission Control",
        33: "Application windows",
        34: "Show Desktop",
        35: "Show Dashboard",
        36: "Move left a space",
        28: "Screenshot: save to disk",
        29: "Screenshot: copy to clipboard",
        30: "Screenshot of selection: save to disk",
        31: "Screenshot of selection: copy to clipboard",
        184: "Screenshot and recording UI",
    ]

    /// Live enabled symbolic hotkeys as `HotkeyConflictChecker.SystemDefault`s. Missing plist,
    /// missing key, or an unparseable entry are all treated as "no known system default" —
    /// never a crash, since this reads a file outside the app's own control.
    static func enabledDefaults() -> [HotkeyConflictChecker.SystemDefault] {
        guard let defaults = UserDefaults(suiteName: "com.apple.symbolichotkeys"),
              let root = defaults.dictionary(forKey: "AppleSymbolicHotKeys") else { return [] }
        var result: [HotkeyConflictChecker.SystemDefault] = []
        for (idString, description) in knownIDs {
            guard let entry = root["\(idString)"] as? [String: Any],
                  entry["enabled"] as? Bool == true,
                  let value = entry["value"] as? [String: Any],
                  let params = value["parameters"] as? [Any], params.count >= 3,
                  let keyCode = params[1] as? Int,
                  let modifierFlags = params[2] as? Int,
                  let binding = Self.binding(keyCode: keyCode, modifierFlags: modifierFlags) else { continue }
            result.append(.init(binding: binding, description: description))
        }
        return result
    }

    /// Virtual key code + modifier mask -> our framework-independent `HotkeyBinding`. The
    /// plist's `parameters[2]` is an `NSEvent.ModifierFlags` raw value (verified against a
    /// live plist: Control alone reads 262144 = 0x40000 = NSEvent.ModifierFlags.control),
    /// NOT the classic Carbon Event Manager modifier mask its neighbouring `type: "standard"`
    /// naming might suggest — using Carbon's bit positions here would silently match nothing.
    private static func binding(keyCode: Int, modifierFlags: Int) -> HotkeyBinding? {
        // VirtualKeyCodes.letterAndDigitKeys (HotkeyBinding.swift): the single Carbon
        // virtual-key-code table both this reader and OptionChordDecider.swift use — it lives
        // there so it stays framework-independent and a self-test can compile the Option-chord
        // decision logic standalone.
        guard let key = VirtualKeyCodes.letterAndDigitKeys[keyCode] else { return nil }
        let flags = NSEvent.ModifierFlags(rawValue: UInt(modifierFlags))
        return HotkeyBinding(key,
                              shift: flags.contains(.shift),
                              option: flags.contains(.option),
                              control: flags.contains(.control),
                              command: flags.contains(.command))
    }
}
