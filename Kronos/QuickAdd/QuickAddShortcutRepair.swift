// Kronos/QuickAdd/QuickAddShortcutRepair.swift
// Pure predicate for QuickAddController's one-shot repair of the global quick-add shortcut
// (see that file's `repairQuickAddShortcutIfMigrationDisabledIt` for the root-cause writeup).
// Split out so `scripts/quickadd-shortcut-repair-selftest.swift` can compile this exact file
// standalone against a hand-written table, following the project's "compile the real source"
// self-test convention — the class it is called from pulls in AppKit/KeyboardShortcuts and
// cannot be built that way.
import Foundation

enum QuickAddShortcutRepair {
    /// Repair once, and only once, when the shortcut is missing at that moment. Never runs
    /// again afterwards (even if the user deliberately clears the shortcut later via
    /// `SettingsShortcutsTab`'s `KeyboardShortcuts.Recorder`, which reaches the same on-disk
    /// "disabled" state as the bug and cannot be told apart from it): fixing the one known
    /// migration bug must not fight a real, later, intentional clear.
    static func shouldRepair(alreadyRepaired: Bool, isSnapshot: Bool, hasShortcut: Bool) -> Bool {
        !alreadyRepaired && !isSnapshot && !hasShortcut
    }
}
