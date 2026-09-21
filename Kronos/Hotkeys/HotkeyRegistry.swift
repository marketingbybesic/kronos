// Kronos/Hotkeys/HotkeyRegistry.swift
// Single source of truth for every shortcut in the app. Menus (KronosApp.swift), the list's
// key handling (TaskListScreen.swift) and the global hotkeys (QuickAddController.swift) all
// read bindings from here instead of hard-coding a key — `scripts/verify-hotkeys.mjs` fails
// the build if a literal shortcut drifts from this file.
//
// A future Settings > Shortcuts table and the keymap sheet would read `HotkeyRegistry.grouped()`
// and `HotkeyRegistry.current(for:)` as their public surface; `HotkeyRegistry.changed`
// notification is what would invalidate their rows.
import Foundation
import SwiftUI
import KeyboardShortcuts
import Carbon.HIToolbox

/// Where a binding is enforced. `global` bindings work anywhere on the Mac (KeyboardShortcuts);
/// every other scope is only live while its part of the window has focus — plain SwiftUI
/// `.keyboardShortcut` / `.onKeyPress`.
public enum HotkeyScope: String, Codable, CaseIterable, Sendable {
    case global, window, list, popover, editor
}

// HotkeyBinding's core struct + `displayKeys` live in HotkeyBinding.swift (Foundation-only,
// so scripts/hotkey-accept-selftest.swift can compile it standalone). This extension adds
// the SwiftUI/KeyboardShortcuts-specific members, which need the frameworks this file already
// imports.
extension HotkeyBinding {
    var modifiers: SwiftUI.EventModifiers {
        var m: SwiftUI.EventModifiers = []
        if shift { m.insert(.shift) }
        if option { m.insert(.option) }
        if control { m.insert(.control) }
        if command { m.insert(.command) }
        return m
    }

    /// SwiftUI's `.keyboardShortcut(_:modifiers:)` equivalent for a plain character key.
    /// `key.count == 1` used to silently exclude `"backslash"` (9 characters, the registry's
    /// own spelling — see `namedKeys`/`displayNames` below, which already know it as one
    /// symbol) — `window.sidebar` (⌘\\) got NO `.keyboardShortcut` at all, confirmed live in
    /// the menu dump (`key='-' mods=0`). `Self.symbolKeys` translates the handful of named
    /// keys this registry actually stores as multi-character strings to their real character
    /// FIRST; anything left over falls back to the single-character case (letters/digits).
    /// Other named keys (space/return/escape/arrows/…) still correctly have no mapping here —
    /// window-scope commands never bind those (Return/Esc/arrows inside editors are not
    /// registry entries, see the verify script's own allow-list).
    var keyEquivalent: KeyEquivalent? {
        if key == "backslash" { return KeyEquivalent("\\") }
        return key.count == 1 ? KeyEquivalent(Character(key)) : nil
    }

    /// LIVE `displayKeys`: what the Shortcuts settings tab, the command-palette keymap sheet
    /// and the recorder field all actually show (every real call site uses plain `.displayKeys`
    /// — no other place prints its own shortcut string, grepped). Supplies a translator that
    /// reads the CURRENT keyboard layout via Carbon, computed at RENDER TIME (never cached),
    /// so it follows a layout switch without an app restart. The fixed symbol table used to
    /// always show a hand-picked character (`\\` for backslash) even once `.automatic`
    /// localization remaps that physical key elsewhere on a non-US layout (confirmed live:
    /// Cmd-\\ actually fires as Cmd-Ž on a Croatian keyboard layout) — the tab would tell a
    /// user to press a key their keyboard cannot produce unshifted. `displayKeys(translate:)`
    /// (HotkeyBinding.swift) is the pure, testable core; this is its one live call site.
    var displayKeys: [String] {
        displayKeys(translate: { vk in Self.currentLayoutCharacter(forKeyCode: vk) })
    }

    /// Translates a physical (Carbon) virtual key code through whatever keyboard layout is
    /// selected RIGHT NOW — same UCKeyTranslate mechanism `LiveUITest+Hotkeys.swift`'s
    /// `KeyLayout` uses for a NAMED layout, but here always the live one (no modifiers: this
    /// is "what does this key print unshifted", the same question `displayKeys` asks for
    /// every other key).
    private static func currentLayoutCharacter(forKeyCode keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let dataPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(dataPtr).takeUnretainedValue()
        guard let base = CFDataGetBytePtr(data) else { return nil }
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var actualLen = 0
        let status = base.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layoutPtr in
            UCKeyTranslate(layoutPtr, keyCode, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                            OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, 4, &actualLen, &chars)
        }
        guard status == noErr, actualLen > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: actualLen)
    }

    /// KeyboardShortcuts' own shortcut type, for `global`-scope bindings only.
    var globalShortcut: KeyboardShortcuts.Shortcut? {
        guard let namedKey = Self.namedKeys[key] else { return nil }
        var flags: NSEvent.ModifierFlags = []
        if shift { flags.insert(.shift) }
        if option { flags.insert(.option) }
        if control { flags.insert(.control) }
        if command { flags.insert(.command) }
        return KeyboardShortcuts.Shortcut(namedKey, modifiers: flags)
    }

    /// `KeyboardShortcuts.Key` for the small fixed set this app actually binds globally
    /// (letters, digits, space, backslash). Not a general keyboard-layout mapper.
    private static let namedKeys: [String: KeyboardShortcuts.Key] = [
        "a": .a, "b": .b, "c": .c, "d": .d, "e": .e, "f": .f, "g": .g, "h": .h, "i": .i,
        "j": .j, "k": .k, "l": .l, "m": .m, "n": .n, "o": .o, "p": .p, "q": .q, "r": .r,
        "s": .s, "t": .t, "u": .u, "v": .v, "w": .w, "x": .x, "y": .y, "z": .z,
        "0": .zero, "1": .one, "2": .two, "3": .three, "4": .four,
        "5": .five, "6": .six, "7": .seven, "8": .eight, "9": .nine,
        "space": .space, "backslash": .backslash,
    ]
}

/// One entry: a stable identity, where it fires, what it defaults to, and where the binding
/// is actually consumed (for a future Settings screen to point someone at code).
public struct HotkeyEntry: Identifiable, Equatable, Sendable {
    public let id: String
    /// String-catalog key (lowercase dotted) for the human title. A missing key is a
    /// localization gap to report, never one to invent a string for here.
    public let titleKey: String
    public let scope: HotkeyScope
    public let defaultBinding: HotkeyBinding
    public let isRebindable: Bool
    /// File:site the binding is wired at, for a human reading a conflict or building Settings.
    public let registrationSite: String

    public static func == (a: HotkeyEntry, b: HotkeyEntry) -> Bool { a.id == b.id }
}

/// The registry itself: fixed entries + user overrides. `@MainActor` because `KeyboardShortcuts`
/// registration and UserDefaults reads/writes from SwiftUI call sites are already main-actor.
@MainActor
public enum HotkeyRegistry {
    /// Posted whenever a user override changes, so a Settings table or keymap sheet can
    /// invalidate its rows without polling.
    public static let changed = Notification.Name("kronosHotkeyRegistryChanged")

    // No "hotkey.global.*" string keys exist in the catalog for these three ids. Each below
    // reuses the closest existing key that already names the same destination/action rather
    // than referencing an absent one (gate-app.mjs's string-key lint would fail the build on a
    // literal that is not in Localizable.xcstrings).
    //
    // `nonisolated`: a plain constant array of `Sendable` value types — QuickAddController
    // reads it from `KeyboardShortcuts.Name`'s nonisolated static-let default-value context.
    public nonisolated static let entries: [HotkeyEntry] = [
        // MARK: Global (KeyboardShortcuts; live system-wide)
        HotkeyEntry(id: "global.quickadd", titleKey: "hotkey.global.quickadd", scope: .global,
                    defaultBinding: HotkeyBinding("k", option: true, control: true), isRebindable: true,
                    registrationSite: "Kronos/QuickAdd/QuickAddController.swift"),
        // No key for "meeting capture" exists (closest, "menu.task.capture", is the DIFFERENT
        // paste-notes Capture feature already used by `window.capture` below) — reusing it here
        // would show two different shortcuts under the same title. "list.new" ("New task") is
        // used instead as a neutral placeholder until a "hotkey.global.meetingcapture" key
        // exists.
        HotkeyEntry(id: "global.meetingcapture", titleKey: "hotkey.global.meetingcapture", scope: .global,
                    defaultBinding: HotkeyBinding("m", option: true, control: true), isRebindable: true,
                    registrationSite: "Kronos/QuickAdd/QuickAddController.swift"),
        HotkeyEntry(id: "global.showordo", titleKey: "hotkey.global.showordo", scope: .global,
                    defaultBinding: HotkeyBinding("o", option: true, control: true), isRebindable: true,
                    registrationSite: "Kronos/QuickAdd/QuickAddController.swift"),

        // MARK: Window (menu commands — KronosApp.swift)
        HotkeyEntry(id: "window.newtask", titleKey: "menu.file.newtask", scope: .window,
                    defaultBinding: HotkeyBinding("n", command: true), isRebindable: false,
                    registrationSite: "Kronos/App/KronosApp.swift"),
        HotkeyEntry(id: "window.find", titleKey: "menu.edit.find", scope: .window,
                    defaultBinding: HotkeyBinding("f", command: true), isRebindable: false,
                    registrationSite: "Kronos/App/KronosApp.swift"),
        HotkeyEntry(id: "window.undo", titleKey: "menu.edit.undo", scope: .window,
                    defaultBinding: HotkeyBinding("z", command: true), isRebindable: false,
                    registrationSite: "Kronos/App/KronosApp.swift"),
        HotkeyEntry(id: "window.redo", titleKey: "menu.edit.redo", scope: .window,
                    defaultBinding: HotkeyBinding("z", shift: true, command: true), isRebindable: false,
                    registrationSite: "Kronos/App/KronosApp.swift"),
        HotkeyEntry(id: "window.viewoptions", titleKey: "viewoptions.title", scope: .window,
                    defaultBinding: HotkeyBinding("f", option: true, command: true), isRebindable: true,
                    registrationSite: "Kronos/App/KronosApp.swift"),
        HotkeyEntry(id: "window.inspector", titleKey: "menu.view.inspector", scope: .window,
                    defaultBinding: HotkeyBinding("i", command: true), isRebindable: true,
                    registrationSite: "Kronos/App/KronosApp.swift"),
        HotkeyEntry(id: "window.sidebar", titleKey: "menu.view.sidebar", scope: .window,
                    defaultBinding: HotkeyBinding("backslash", command: true), isRebindable: true,
                    registrationSite: "Kronos/App/KronosApp.swift"),
        HotkeyEntry(id: "window.chroma.focus", titleKey: "chroma.mode.focus", scope: .window,
                    defaultBinding: HotkeyBinding("1", control: true, command: true), isRebindable: true,
                    registrationSite: "Kronos/App/KronosApp.swift"),
        HotkeyEntry(id: "window.chroma.full", titleKey: "chroma.mode.full", scope: .window,
                    defaultBinding: HotkeyBinding("2", control: true, command: true), isRebindable: true,
                    registrationSite: "Kronos/App/KronosApp.swift"),
        HotkeyEntry(id: "window.chroma.calm", titleKey: "chroma.mode.calm", scope: .window,
                    defaultBinding: HotkeyBinding("3", control: true, command: true), isRebindable: true,
                    registrationSite: "Kronos/App/KronosApp.swift"),
        HotkeyEntry(id: "window.impuls", titleKey: "menu.task.impuls", scope: .window,
                    defaultBinding: HotkeyBinding("i", shift: true, command: true), isRebindable: true,
                    registrationSite: "Kronos/App/KronosApp.swift"),
        HotkeyEntry(id: "window.triage", titleKey: "menu.task.triage", scope: .window,
                    defaultBinding: HotkeyBinding("t", option: true, command: true), isRebindable: true,
                    registrationSite: "Kronos/App/KronosApp.swift"),
        HotkeyEntry(id: "window.capture", titleKey: "menu.task.capture", scope: .window,
                    defaultBinding: HotkeyBinding("n", shift: true, command: true), isRebindable: true,
                    registrationSite: "Kronos/App/KronosApp.swift"),
        HotkeyEntry(id: "window.palette", titleKey: "menu.view.palette", scope: .window,
                    defaultBinding: HotkeyBinding("k", command: true), isRebindable: false,
                    registrationSite: "Kronos/App/KronosApp.swift"),
        HotkeyEntry(id: "window.timeblocks", titleKey: "timeblocks.title", scope: .window,
                    defaultBinding: HotkeyBinding("b", option: true, command: true), isRebindable: true,
                    registrationSite: "Kronos/App/KronosApp.swift"),
        HotkeyEntry(id: "window.goto.1", titleKey: "sidebar.inbox", scope: .window,
                    defaultBinding: HotkeyBinding("1", command: true), isRebindable: false,
                    registrationSite: "Kronos/App/KronosApp.swift"),
        HotkeyEntry(id: "window.goto.2", titleKey: "sidebar.today", scope: .window,
                    defaultBinding: HotkeyBinding("2", command: true), isRebindable: false,
                    registrationSite: "Kronos/App/KronosApp.swift"),
        HotkeyEntry(id: "window.goto.3", titleKey: "sidebar.next7", scope: .window,
                    defaultBinding: HotkeyBinding("3", command: true), isRebindable: false,
                    registrationSite: "Kronos/App/KronosApp.swift"),
        HotkeyEntry(id: "window.goto.4", titleKey: "sidebar.waiting", scope: .window,
                    defaultBinding: HotkeyBinding("4", command: true), isRebindable: false,
                    registrationSite: "Kronos/App/KronosApp.swift"),
        HotkeyEntry(id: "window.goto.5", titleKey: "sidebar.someday", scope: .window,
                    defaultBinding: HotkeyBinding("5", command: true), isRebindable: false,
                    registrationSite: "Kronos/App/KronosApp.swift"),
        HotkeyEntry(id: "window.goto.6", titleKey: "sidebar.all", scope: .window,
                    defaultBinding: HotkeyBinding("6", command: true), isRebindable: false,
                    registrationSite: "Kronos/App/KronosApp.swift"),

        // MARK: List (TaskListScreen.swift; live only while the list has focus)
        // No "hotkey.list.*" string keys exist in the catalog. Each below reuses the closest
        // existing key naming the same action; up/down share "palette.hint.navigate"
        // ("Navigate") since they are one action in two directions.
        HotkeyEntry(id: "list.up", titleKey: "hotkey.list.up", scope: .list,
                    defaultBinding: HotkeyBinding("up"), isRebindable: false,
                    registrationSite: "Kronos/List/TaskListScreen.swift"),
        HotkeyEntry(id: "list.down", titleKey: "hotkey.list.down", scope: .list,
                    defaultBinding: HotkeyBinding("down"), isRebindable: false,
                    registrationSite: "Kronos/List/TaskListScreen.swift"),
        HotkeyEntry(id: "list.toggle", titleKey: "hotkey.list.toggle", scope: .list,
                    defaultBinding: HotkeyBinding("space"), isRebindable: false,
                    registrationSite: "Kronos/List/TaskListScreen.swift"),
        HotkeyEntry(id: "list.delete", titleKey: "hotkey.list.delete", scope: .list,
                    defaultBinding: HotkeyBinding("delete"), isRebindable: false,
                    registrationSite: "Kronos/List/TaskListScreen.swift"),
        HotkeyEntry(id: "list.open", titleKey: "hotkey.list.open", scope: .list,
                    defaultBinding: HotkeyBinding("return"), isRebindable: false,
                    registrationSite: "Kronos/List/TaskListScreen.swift"),
        HotkeyEntry(id: "list.snooze", titleKey: "hotkey.list.snooze", scope: .list,
                    defaultBinding: HotkeyBinding("h"), isRebindable: true,
                    registrationSite: "Kronos/List/TaskListScreen.swift"),
        HotkeyEntry(id: "list.focuspin", titleKey: "hotkey.list.focuspin", scope: .list,
                    defaultBinding: HotkeyBinding("f"), isRebindable: true,
                    registrationSite: "Kronos/List/TaskListScreen.swift"),
        HotkeyEntry(id: "list.expandall", titleKey: "hotkey.list.expandall", scope: .list,
                    defaultBinding: HotkeyBinding("e"), isRebindable: true,
                    registrationSite: "Kronos/List/TaskListScreen.swift"),
        HotkeyEntry(id: "list.priority.none", titleKey: "hotkey.list.priority.none", scope: .list,
                    defaultBinding: HotkeyBinding("0"), isRebindable: false,
                    registrationSite: "Kronos/List/TaskListScreen.swift"),
        HotkeyEntry(id: "list.priority.low", titleKey: "hotkey.list.priority.low", scope: .list,
                    defaultBinding: HotkeyBinding("1"), isRebindable: false,
                    registrationSite: "Kronos/List/TaskListScreen.swift"),
        HotkeyEntry(id: "list.priority.medium", titleKey: "hotkey.list.priority.medium", scope: .list,
                    defaultBinding: HotkeyBinding("2"), isRebindable: false,
                    registrationSite: "Kronos/List/TaskListScreen.swift"),
        HotkeyEntry(id: "list.priority.high", titleKey: "hotkey.list.priority.high", scope: .list,
                    defaultBinding: HotkeyBinding("3"), isRebindable: false,
                    registrationSite: "Kronos/List/TaskListScreen.swift"),
        HotkeyEntry(id: "list.priority.urgent", titleKey: "hotkey.list.priority.urgent", scope: .list,
                    defaultBinding: HotkeyBinding("4"), isRebindable: false,
                    registrationSite: "Kronos/List/TaskListScreen.swift"),
    ]

    // MARK: User overrides (UserDefaults; hermetic under KRONOS_SNAPSHOT, mirrors AppModel.persist)

    private static let overrideKey = "kronos.hotkeys.overrides.v1"
    private static let migratedQuickAddKey = "kronos.hotkeys.migratedQuickAddDefault.v1"

    private static var isHermetic: Bool { ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT"] != nil }

    private static func loadOverrides() -> [String: HotkeyBinding] {
        guard !isHermetic, let data = UserDefaults.standard.data(forKey: overrideKey),
              let v = try? JSONDecoder().decode([String: HotkeyBinding].self, from: data) else { return [:] }
        return v
    }

    private static func saveOverrides(_ overrides: [String: HotkeyBinding]) {
        guard !isHermetic else { return }
        if let data = try? JSONEncoder().encode(overrides) {
            UserDefaults.standard.set(data, forKey: overrideKey)
        }
    }

    /// The binding actually in effect: user override if one exists and the entry allows
    /// rebinding, else the default.
    public static func current(for id: String) -> HotkeyBinding? {
        guard let entry = entries.first(where: { $0.id == id }) else { return nil }
        if entry.isRebindable, let override = loadOverrides()[id] { return override }
        return entry.defaultBinding
    }

    public static func setOverride(_ binding: HotkeyBinding?, for id: String) {
        guard let entry = entries.first(where: { $0.id == id }), entry.isRebindable else { return }
        var overrides = loadOverrides()
        if let binding { overrides[id] = binding } else { overrides.removeValue(forKey: id) }
        saveOverrides(overrides)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    public static func resetToDefaults() {
        saveOverrides([:])
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// One-time silent migration: a user who never touched the old ⌥Space quick-add default
    /// moves to the new clash-free default; anyone who customised it keeps their own choice.
    /// Call once from AppDelegate before `QuickAddController.start()`.
    public static func migrateLegacyQuickAddDefaultIfNeeded() {
        guard !isHermetic, !UserDefaults.standard.bool(forKey: migratedQuickAddKey) else { return }
        UserDefaults.standard.set(true, forKey: migratedQuickAddKey)
        let legacyDefault = KeyboardShortcuts.Shortcut(.space, modifiers: [.option])
        if KeyboardShortcuts.getShortcut(for: .quickAdd) == legacyDefault {
            // NOT reset(): for a name that has a default, the library's reset() stores the value
            // `false` (= disabled), and the default is only ever written when the key is absent,
            // so without this migration the shortcut would stay off for good once a user's
            // defaults already held the legacy value.
            KeyboardShortcuts.setShortcut(KeyboardShortcuts.Shortcut(.k, modifiers: [.control, .option]), for: .quickAdd)
        }
    }

    /// Grouped by scope, in `HotkeyScope.allCases` order, for a future Settings table.
    public static func grouped() -> [(scope: HotkeyScope, entries: [HotkeyEntry])] {
        HotkeyScope.allCases.map { scope in (scope, entries.filter { $0.scope == scope }) }
    }
}
