// Kronos/Board/BoardKeyMonitor.swift
// Kronos v1.2 Phase 2 slice F2 follow-up: a SECOND, independent path to BoardKeyActions,
// parallel to the `.onKeyPress(characters: boardCharacterSet)` handling in BoardScreen.swift.
// Confirmed live (a removed trace): `moveSelected` is never called for a plain, unmodified
// character on a `.focusable(true, interactions: .activate)` + `@FocusState` region under a
// synthetic (not real-hardware) keyDown — the same class of limitation OptionChordMonitor.swift
// documents for Option-held menu chords and AgentKeyMonitor.swift documents for Command-held
// list chords, here affecting Board's plain `[`/`]`. A local key monitor catches the keyDown
// directly and calls the exact same BoardKeyActions.moveSelected the onKeyPress path calls, so
// the two paths can never drift. Board-scope only: stands down unless the Board layout is
// showing, no text field is first responder, and the key window is Kronos's own main window —
// the same guard shape AgentKeyMonitor.swift uses for its own list-scope-only stand-down.
import AppKit
import KronosCore

@MainActor
enum BoardKeyMonitor {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event) ? nil : event
        }
    }

    /// Registry ids for `[`/`]` — the SAME ids BoardScreen.swift's own `boardCharacterSet` reads
    /// live, so a Settings rebind changes what both paths accept, never just one of them.
    private static let leftID = "board.movecolumn.left"
    private static let rightID = "board.movecolumn.right"

    private static func handle(_ event: NSEvent) -> Bool {
        guard let model = AppDelegate.shared?.model,
              let key = NSApp.keyWindow ?? NSApp.mainWindow, !(key is NSPanel), key.title == "Kronos",
              !(key.firstResponder is NSTextView),
              model.options(for: model.scope).layout == .board
        else { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods.isDisjoint(with: [.command, .control, .option]) else { return false }
        guard let chars = event.charactersIgnoringModifiers?.lowercased(), chars.count == 1 else { return false }
        let left = (HotkeyRegistry.current(for: leftID)?.key ?? "[").lowercased()
        let right = (HotkeyRegistry.current(for: rightID)?.key ?? "]").lowercased()
        guard chars == left || chars == right else { return false }
        BoardKeyActions.moveSelected(forward: chars == right, model: model)
        return true
    }
}
