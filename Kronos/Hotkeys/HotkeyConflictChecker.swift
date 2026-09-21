// Kronos/Hotkeys/HotkeyConflictChecker.swift
// Answers "would this binding clash with something?" for three cases: (a) another entry in
// the same scope, (b) for a GLOBAL binding, a macOS symbolic hotkey or a common installed
// app's own default, (c) for a WINDOW binding, a protected standard editing/window shortcut.
//
// Honesty limit, stated for any UI that surfaces this: arbitrary third-party app hotkeys
// that are neither a macOS symbolic hotkey nor in `bundledAppDefaults` below CANNOT be
// detected. This checker only ever says "no known conflict", never "definitely free".
import Foundation
import AppKit

public struct HotkeyConflict: Equatable, Sendable {
    /// What this clashes with, for UI copy ("Clashes with Raycast", "Clashes with Spotlight",
    /// "Clashes with ⌘C Copy", "Clashes with another Kronos shortcut").
    public let describesClash: String
}

@MainActor
public enum HotkeyConflictChecker {

    /// (c) Standard macOS editing/window shortcuts a WINDOW-scope binding must not shadow.
    /// Cmd + one of these letters/symbols, no other modifier — matches how these actually
    /// register system-wide inside any app (Edit menu, Window menu).
    private static let protectedStandardBindings: [HotkeyBinding: String] = [
        HotkeyBinding("c", command: true): "⌘C Copy",
        HotkeyBinding("v", command: true): "⌘V Paste",
        HotkeyBinding("x", command: true): "⌘X Cut",
        HotkeyBinding("z", command: true): "⌘Z Undo",
        HotkeyBinding("z", shift: true, command: true): "⌘⇧Z Redo",
        HotkeyBinding("a", command: true): "⌘A Select All",
        HotkeyBinding("w", command: true): "⌘W Close Window",
        HotkeyBinding("q", command: true): "⌘Q Quit",
        HotkeyBinding("m", command: true): "⌘M Minimize",
        HotkeyBinding("h", command: true): "⌘H Hide",
        HotkeyBinding(",", command: true): "⌘, Preferences",
        HotkeyBinding("`", command: true): "⌘` Cycle Windows",
    ]

    /// (b) Common app defaults, filtered by the caller to apps actually installed. Global
    /// quick-entry launchers are the sharpest, most-reported clash, which is why the default
    /// quick-add binding is not ⌥Space — Raycast/Alfred/ChatGPT/Claude/1Password are common
    /// launchers; Rectangle/CleanShot round out window/capture tools.
    struct BundledAppDefault {
        let bundleID: String
        let appName: String
        let binding: HotkeyBinding
        let description: String
    }

    static let bundledAppDefaults: [BundledAppDefault] = [
        .init(bundleID: "com.raycast.macos", appName: "Raycast",
              binding: HotkeyBinding("space", option: true), description: "Raycast quick entry (⌥Space)"),
        .init(bundleID: "com.runningwithcrayons.Alfred", appName: "Alfred",
              binding: HotkeyBinding("space", option: true), description: "Alfred quick entry (⌥Space)"),
        .init(bundleID: "com.openai.chat", appName: "ChatGPT",
              binding: HotkeyBinding("space", option: true), description: "ChatGPT quick entry (⌥Space)"),
        .init(bundleID: "com.anthropic.claudefordesktop", appName: "Claude",
              binding: HotkeyBinding("space", option: true), description: "Claude quick entry (⌥Space)"),
        .init(bundleID: "com.1password.1password", appName: "1Password",
              binding: HotkeyBinding("backslash", option: true, command: true), description: "1Password Quick Access (⌥⌘\\)"),
        .init(bundleID: "com.knollsoft.Rectangle", appName: "Rectangle",
              binding: HotkeyBinding("return", option: true, control: true), description: "Rectangle Maximize (⌃⌥⏎)"),
        .init(bundleID: "co.cleanshot.cleanshot-cloud", appName: "CleanShot X",
              binding: HotkeyBinding("5", shift: true, command: true), description: "CleanShot capture (⇧⌘5)"),
    ]

    /// (b) macOS's own reserved shortcuts — read live from the symbolic-hotkeys plist by
    /// `SymbolicHotkeyReader`, which already resolves them into `HotkeyBinding`s with a name.
    struct SystemDefault {
        let binding: HotkeyBinding
        let description: String
    }

    // MARK: Checks

    /// Duplicate bindings within one scope, across ALL entries (defaults + effective user
    /// overrides). Returns one conflict per id pair, both directions collapsed.
    static func duplicatesWithinScope(effective: [(id: String, scope: HotkeyScope, binding: HotkeyBinding)]) -> [String: HotkeyConflict] {
        var result: [String: HotkeyConflict] = [:]
        for scope in HotkeyScope.allCases {
            let inScope = effective.filter { $0.scope == scope }
            for a in inScope {
                for b in inScope where b.id != a.id && b.binding == a.binding {
                    result[a.id] = HotkeyConflict(describesClash: "another Kronos shortcut (\(b.id))")
                }
            }
        }
        return result
    }

    /// A recorded binding checked against every FIXED (non-rebindable) entry in the registry,
    /// across EVERY scope: a recorded window/global combination must also be flagged if it
    /// equals one of the list's fixed keys (Space/H/F/0-4/…), not only another entry in its
    /// own scope. `duplicatesWithinScope` above stays scope-local (two rebindable entries only
    /// really compete while both are live at once, which is a same-scope question); a FIXED
    /// key can never be reassigned away, so any overlap with one is a real clash regardless of
    /// scope.
    static func fixedKeyConflict(_ binding: HotkeyBinding, entryID: String? = nil) -> HotkeyConflict? {
        guard let hit = HotkeyRegistry.entries.first(where: { !$0.isRebindable && $0.id != entryID && $0.defaultBinding == binding })
        else { return nil }
        return HotkeyConflict(describesClash: "a fixed Kronos shortcut (\(hit.id))")
    }

    /// A GLOBAL binding checked against live macOS symbolic hotkeys + installed common apps.
    static func globalConflict(_ binding: HotkeyBinding,
                                systemDefaults: [SystemDefault],
                                installedBundleIDs: Set<String>) -> HotkeyConflict? {
        if let hit = systemDefaults.first(where: { $0.binding == binding }) {
            return HotkeyConflict(describesClash: hit.description)
        }
        if let hit = bundledAppDefaults.first(where: { $0.binding == binding && installedBundleIDs.contains($0.bundleID) }) {
            return HotkeyConflict(describesClash: hit.description)
        }
        return nil
    }

    /// A WINDOW binding checked against protected standard shortcuts.
    /// `entryID` = the registry entry being checked. An entry that IS the standard shortcut
    /// (Kronos's own Undo on Cmd-Z, Redo on Shift-Cmd-Z) does not clash with itself: the
    /// protection is against OTHER commands taking those keys.
    static func windowConflict(_ binding: HotkeyBinding, entryID: String? = nil) -> HotkeyConflict? {
        guard let name = protectedStandardBindings[binding] else { return nil }
        if let entryID, let entry = HotkeyRegistry.entries.first(where: { $0.id == entryID }),
           entry.defaultBinding == binding { return nil }
        return HotkeyConflict(describesClash: name)
    }

    /// Convenience used by the app and by the verify script's Swift-side self-test:
    /// bundle IDs of the table above that are actually installed on this Mac.
    static func installedBundleIDs() -> Set<String> {
        Set(bundledAppDefaults
            .map(\.bundleID)
            .filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil })
    }
}
