// Kronos/Settings/SettingsShortcutsTab.swift
// The single searchable table of every shortcut in the app, read entirely from
// `HotkeyRegistry` (Kronos/Hotkeys/** — this file never keeps a second list). Grouped by
// scope, a recorder for rebindable entries, a calm named conflict note per entry via
// `HotkeyConflictChecker`, "Reset to defaults". The quick-add recorder this tab already had
// lives on inside the Global group as `global.quickadd`, so it is not duplicated.
import AppKit
import SwiftUI
import KeyboardShortcuts
import KronosCore

struct SettingsShortcutsTab: View {
    @State private var query: String = ""
    @State private var overrideVersion = 0
    @State private var confirmingReset = false
    private let installedBundleIDs = HotkeyConflictChecker.installedBundleIDs()
    private let systemDefaults = SymbolicHotkeyReader.enabledDefaults()

    var body: some View {
        SettingsSection(title: String(localized: "settings.tab.shortcuts")) {
            KTextField(String(localized: "settings.shortcuts.search"), text: $query, leading: "search")
                .frame(width: 260)
                .uiTestAnchor("settings.shortcuts.search")
            // Honesty limit stated once for the whole table: arbitrary third-party app
            // hotkeys CANNOT be detected (HotkeyConflictChecker's own header comment repeats
            // this), rather than repeating it per row.
            Text(String(localized: "settings.shortcuts.honest"))
                .font(Typo.meta)
                .foregroundStyle(Tok.textTertiary)
                .padding(.top, Space.x1)
        }

        ForEach(HotkeyRegistry.grouped(), id: \.scope) { group in
            let rows = group.entries.filter(matchesQuery)
            if !rows.isEmpty {
                SettingsSection(title: scopeTitle(group.scope)) {
                    // A scope can mix pill (rebindable) and bare-text (fixed) rows — e.g. "In
                    // the list" has Snooze/Pin/Show-all alongside Space/H/0-4 — so a reader
                    // needs telling the bare ones are fixed ON PURPOSE, not just not-yet-built.
                    // One caption per scope that has any fixed row at all, rather than a
                    // per-row note.
                    if rows.contains(where: { !$0.isRebindable }) {
                        Text(String(localized: "settings.shortcuts.fixed"))
                            .font(Typo.meta)
                            .foregroundStyle(Tok.textTertiary)
                            .padding(.bottom, Space.x1)
                    }
                    ForEach(rows) { entry in
                        shortcutRow(entry)
                    }
                }
            }
        }

        if confirmingReset {
            HStack {
                Text(String(localized: "settings.shortcuts.reset.confirm"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                Spacer(minLength: Space.x4)
                Button(String(localized: "settings.shortcuts.reset")) {
                    HotkeyRegistry.resetToDefaults()
                    resetNamedGlobalShortcutsToDefaults()
                    overrideVersion += 1
                    confirmingReset = false
                }
                .kButton(.secondary, size: .compact)
                .fixedSize()
                Button(String(localized: "common.cancel")) { confirmingReset = false }
                    .kButton(.ghost, size: .compact)
                    .fixedSize()
            }
        } else {
            SettingsTrailingRow {
                Button(String(localized: "settings.shortcuts.reset")) { confirmingReset = true }
                    .kButton(.ghost, size: .compact)
                    .fixedSize()
                    .uiTestAnchor("settings.shortcuts.reset")
            }
        }
    }

    /// "Reset to defaults" must restore EVERY row, including the three globals — those live
    /// in `KeyboardShortcuts`' own UserDefaults storage, untouched by
    /// `HotkeyRegistry.resetToDefaults()`. Never `.reset()` a Name that has a `default:` — the
    /// package writes a "disabled" sentinel instead of clearing the stored value (this is the
    /// exact bug QuickAddController.swift:57-85 already had to repair once). `.setShortcut`
    /// with the registry's own default is the real restore.
    private func resetNamedGlobalShortcutsToDefaults() {
        for (id, name) in Self.namedGlobalShortcuts {
            guard let binding = HotkeyRegistry.entries.first(where: { $0.id == id })?.defaultBinding,
                  let shortcut = binding.globalShortcut else { continue }
            KeyboardShortcuts.setShortcut(shortcut, for: name)
        }
    }

    private func matchesQuery(_ entry: HotkeyEntry) -> Bool {
        guard !query.isEmpty else { return true }
        let title = title(for: entry)
        return KTextFold.fold(title).contains(KTextFold.fold(query))
    }

    private func scopeTitle(_ scope: HotkeyScope) -> String {
        switch scope {
        case .global: return String(localized: "settings.shortcuts.scope.global")
        case .window: return String(localized: "settings.shortcuts.scope.window")
        case .list: return String(localized: "settings.shortcuts.scope.list")
        case .popover: return String(localized: "settings.shortcuts.scope.popover")
        case .editor: return String(localized: "settings.shortcuts.scope.editor")
        }
    }

    /// Every `titleKey` on the registry's own entries is one already in the catalog (its file's
    /// header comment: reused existing keys rather than inventing one), so this always resolves
    /// to real text — `String(localized:)`'s own behaviour for a key genuinely absent from every
    /// table is to print the key itself, which is still honest (never a crash) for a future entry.
    private func title(for entry: HotkeyEntry) -> String {
        String(localized: String.LocalizationValue(entry.titleKey))
    }

    /// `global.meetingcapture`/`global.showordo` already have real `KeyboardShortcuts.Name`s
    /// (QuickAddController.swift:19-20, registered and listened to independently) — they
    /// rendered through the generic `HotkeyRecorderField` before, which wrote to
    /// `HotkeyRegistry.setOverride`, a DIFFERENT store `KeyboardShortcuts` never reads, so
    /// recording a new combo there visibly "saved" but never actually rebound the live global
    /// hotkey. All three global entries now go through the package's own Recorder, same as
    /// quick-add always did.
    private static let namedGlobalShortcuts: [String: KeyboardShortcuts.Name] = [
        "global.quickadd": .quickAdd,
        "global.meetingcapture": .meetingCapture,
        "global.showordo": .showOrdo,
    ]

    private func shortcutRow(_ entry: HotkeyEntry) -> some View {
        let binding = HotkeyRegistry.current(for: entry.id) ?? entry.defaultBinding
        let conflict = conflict(for: entry, binding: binding)
        return VStack(alignment: .leading, spacing: Space.x1) {
            HStack {
                Text(title(for: entry)).font(Typo.row).foregroundStyle(Tok.textPrimary)
                Spacer(minLength: Space.x4)
                if let name = Self.namedGlobalShortcuts[entry.id] {
                    KeyboardShortcuts.Recorder(for: name)
                        .id(overrideVersion)
                } else if entry.isRebindable {
                    // Every other rebindable entry (window scope) has no `KeyboardShortcuts.Name`,
                    // so it gets `HotkeyRecorderField` instead — writes straight to
                    // `HotkeyRegistry.setOverride`, which `HotkeyViewModifiers.swift`'s
                    // `.hotkey(id)` already reads live (KeyboardShortcuts.Recorder does the
                    // equivalent internally for its own Name).
                    HotkeyRecorderField(id: entry.id, binding: binding,
                                        isOverridden: binding != entry.defaultBinding,
                                        allowsBareKey: entry.scope == .list) { recorded in
                        HotkeyRegistry.setOverride(recorded, for: entry.id)
                        overrideVersion += 1
                    } onResetToDefault: {
                        HotkeyRegistry.setOverride(nil, for: entry.id)
                        overrideVersion += 1
                    }
                    .id("\(entry.id)-\(overrideVersion)")
                    .uiTestAnchor("settings.shortcuts.recorder.\(entry.id)")
                } else {
                    // list/popover/editor-scope entries: the registry itself marks these
                    // `isRebindable: false` (arrows, Space, Return, priority digits, …) —
                    // shown as plain text, no recorder drawn over nothing.
                    keyCaps(binding.displayKeys)
                }
            }
            .frame(height: Metrics.controlRegular)
            if let conflict {
                Text(String(format: String(localized: "settings.shortcuts.conflict"), conflict.describesClash))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
            }
        }
    }

    private func conflict(for entry: HotkeyEntry, binding: HotkeyBinding) -> HotkeyConflict? {
        // A recorded combo must also be checked against every FIXED (non-rebindable) key
        // anywhere in the registry, not only entries in its own scope.
        if let hit = HotkeyConflictChecker.fixedKeyConflict(binding, entryID: entry.id) { return hit }
        switch entry.scope {
        case .global:
            return HotkeyConflictChecker.globalConflict(binding, systemDefaults: systemDefaults, installedBundleIDs: installedBundleIDs)
        case .window:
            return HotkeyConflictChecker.windowConflict(binding, entryID: entry.id)
        case .list, .popover, .editor:
            let effective = HotkeyRegistry.entries.map { e in
                (id: e.id, scope: e.scope, binding: HotkeyRegistry.current(for: e.id) ?? e.defaultBinding)
            }
            return HotkeyConflictChecker.duplicatesWithinScope(effective: effective)[entry.id]
        }
    }

    /// `KKeyHint` (Kronos/DesignSystem) only takes a variadic `String...`, not an array — a
    /// binding's `displayKeys` is 1-4 caps (up to 4 modifiers + the key itself), so every
    /// arity is spelled out explicitly rather than duplicating KKeyHint's own body with literal
    /// tokens (which the lint rightly rejects outside the design system).
    @ViewBuilder
    private func keyCaps(_ keys: [String]) -> some View {
        switch keys.count {
        case 0: EmptyView()
        case 1: KKeyHint(keys[0])
        case 2: KKeyHint(keys[0], keys[1])
        case 3: KKeyHint(keys[0], keys[1], keys[2])
        default: KKeyHint(keys[0], keys[1], keys[2], keys[3])
        }
    }
}
