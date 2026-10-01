// Kronos/Palette/LiveUITest+Palette.swift
// Live step for audit D15/D16: typing into the Cmd-K palette search reaches the field, and
// Cmd-/ opens the keyboard-shortcuts reference (inside the palette, and globally).
// Compiled only outside Release: extends `LiveUITest`, whose real implementation is itself
// compiled out under Release (see LiveUITest.swift). Called from `LiveUITest.run` after
// `paletteFits`: `await paletteTypingAndKeymap(model)`.
#if !RELEASE
import AppKit

@MainActor
extension LiveUITest {
    /// The text the palette's field editor holds right now (the focused NSTextView), nil when
    /// nothing is being edited.
    private static func fieldText() -> String? {
        (window.firstResponder as? NSTextView)?.string
    }

    static func paletteTypingAndKeymap(_ model: AppModel) async {
        model.isPaletteOpen = false
        try? await Task.sleep(for: .milliseconds(300))
        model.isPaletteOpen = true
        try? await Task.sleep(for: .milliseconds(700))

        // Letters: key code 0 is fine, NSTextView inserts `characters`.
        for ch in "snooze" { key(String(ch)); try? await Task.sleep(for: .milliseconds(40)) }
        try? await Task.sleep(for: .milliseconds(300))
        let typed = fieldText()
        record("palette: typed text lands in the search field", typed == "snooze", "field=\(typed ?? "nil")")

        // Cmd-/ inside the palette swaps the card for the shortcuts reference.
        key("/", modifiers: .command, keyCode: 44)
        try? await Task.sleep(for: .milliseconds(500))
        let inPalette = UITestAnchors.frames["palette.keymap"] != nil
        record("palette: Cmd-/ opens the shortcuts reference", inPalette, "keymap anchor=\(inPalette)")
        model.isPaletteOpen = false
        model.isKeymapOpen = false
        try? await Task.sleep(for: .milliseconds(300))

        // Cmd-/ with nothing open: the global shortcut (needs the KronosCommands binding).
        key("/", modifiers: .command, keyCode: 44)
        try? await Task.sleep(for: .milliseconds(500))
        record("global: Cmd-/ opens the shortcuts reference", model.isKeymapOpen, "isKeymapOpen=\(model.isKeymapOpen)")
        model.isKeymapOpen = false
    }
}
#endif
