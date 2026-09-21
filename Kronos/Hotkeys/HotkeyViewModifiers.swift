// Kronos/Hotkeys/HotkeyViewModifiers.swift
// `View.hotkey(_:)`: the one call every window-scope `.keyboardShortcut(...)` in KronosApp.swift
// uses, so the literal key/modifiers live in `HotkeyRegistry` and nowhere else.
import SwiftUI

extension View {
    /// Applies the current (override-or-default) binding for a WINDOW-scope registry id as a
    /// `.keyboardShortcut`. A missing id or one with no plain-key equivalent (there are none
    /// among today's window entries) leaves the view unchanged rather than crashing.
    @MainActor
    func hotkey(_ id: String) -> some View {
        guard let binding = HotkeyRegistry.current(for: id), let key = binding.keyEquivalent else {
            return AnyView(self)
        }
        return AnyView(self.keyboardShortcut(key, modifiers: binding.modifiers))
    }
}
