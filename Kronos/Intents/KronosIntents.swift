// Kronos/Intents/KronosIntents.swift — single entry point.
//
// App Intents / `AppShortcutsProvider` are discovered automatically by the system from the
// app's binary at launch — there is no explicit registration call for the intents
// themselves. This bootstrap exists for the ONE thing that does need an explicit call:
// telling the system the shortcut phrases changed, which `AppShortcutsProvider` recommends
// doing once per meaningful update (e.g. if a user renames Ordo presets in Settings, or on
// first launch after an app update that touches this file's phrase list).
//
// `AppDelegate.applicationDidFinishLaunching` calls `KronosIntents.bootstrap(model:)` after
// `self.model = AppModel(store: store)` and before `seedIfEmpty()`/snapshot early-return,
// since intents may run before the first UI frame.
//
// `AppDelegate.shared` (already set by the time intents fire, since every intent's
// `perform()` reads it lazily) is what the intents themselves resolve against — this
// function does not need to store `model` anywhere, it only exists for the shortcuts
// refresh call.

import AppIntents

enum KronosIntents {
    @MainActor
    static func bootstrap(model: AppModel) {
        // Hermetic: snapshot runs use an in-memory store and must never touch the real
        // Shortcuts database (ledger G9 — "snapshots never touch the real Spotlight index",
        // the same rule applies here since both talk to system daemons outside the sandbox).
        guard !SnapshotHarness.isRequested else { return }
        KronosShortcuts.updateAppShortcutParameters()
    }
}
