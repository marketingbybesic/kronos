// Kronos/Sidebar/SidebarShortcutHint.swift
// The quiet shortcut text at the right edge of the Sort and Pick one sidebar rows. Foundation-only
// (HotkeyBinding is the framework-independent half of the hotkey registry) so a self-test
// compiles it with the real HotkeyBinding.swift.
import Foundation

enum SidebarShortcutHint {
    /// Key caps as one run in the order they are given ("⌥", "⌘", "T" -> "⌥⌘T"); nil for none.
    static func text(caps: [String]) -> String? {
        let run = caps.joined()
        return run.isEmpty ? nil : run
    }

    /// The caps of `binding` in macOS order; nil when nothing is bound. `translate` is the
    /// keyboard-layout seam of `HotkeyBinding.displayKeys(translate:)`.
    static func text(for binding: HotkeyBinding?, translate: (UInt16) -> String?) -> String? {
        guard let binding else { return nil }
        return text(caps: binding.displayKeys(translate: translate))
    }
}
