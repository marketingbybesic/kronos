// Kronos/Hotkeys/HotkeyRecordAcceptance.swift
// Pure acceptance rule for a just-recorded HotkeyRecorderField combination. Foundation only,
// so scripts/hotkey-accept-selftest.swift can compile the REAL file with a hand-written table
// — the launcher pattern every other Core self-test in this repo uses
// (scripts/permissions-selftest.swift etc).
//
// `HotkeyRecorderField.handle(_:)` used to accept a bare, unmodified letter — recording "a"
// for a window-scope command meant typing "a" anywhere afterwards fired it. This rule is the
// one place that decides "is this combination even legal to record", independent of "does it
// collide with something else" (HotkeyConflictChecker's job, still run afterwards).
import Foundation

enum HotkeyAcceptance: Equatable {
    case accepted
    /// `reasonKey`: a string-catalog key for the calm inline hint shown while still recording.
    case rejected(reasonKey: String)
}

enum HotkeyRecordAcceptance {
    /// macOS/system shortcuts that stay off-limits everywhere in this app, not only the
    /// standard editing set `HotkeyConflictChecker.protectedStandardBindings` already checks
    /// (that one only runs for WINDOW scope; this rule runs for every recording, window or
    /// global, since a global recording could just as easily land on Cmd-Q).
    static let reservedBindings: Set<HotkeyBinding> = [
        HotkeyBinding("q", command: true),      // Quit
        HotkeyBinding("w", command: true),      // Close window
        HotkeyBinding("h", command: true),      // Hide
        HotkeyBinding("m", command: true),      // Minimize
        HotkeyBinding("tab", command: true),    // App switcher
        HotkeyBinding("space", command: true),  // Spotlight (also the historic quick-add clash)
        HotkeyBinding(",", command: true),      // Preferences
    ]

    /// Whether a freshly recorded binding may be stored at all. Called BEFORE
    /// `HotkeyConflictChecker` — a rejected binding never reaches the conflict check, since it
    /// is never written.
    /// `allowsBareKey`: list-scope rows (H, F, E) ARE bare letters; the list's key handler is
    /// inert while a text field types, so a bare key is safe there and only there.
    static func evaluate(_ binding: HotkeyBinding, allowsBareKey: Bool = false) -> HotkeyAcceptance {
        guard allowsBareKey || binding.command || binding.control || binding.option else {
            return .rejected(reasonKey: "settings.shortcuts.recording.needsmodifier")
        }
        if reservedBindings.contains(binding) {
            return .rejected(reasonKey: "settings.shortcuts.recording.reserved")
        }
        return .accepted
    }
}
