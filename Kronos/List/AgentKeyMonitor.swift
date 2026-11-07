// Kronos/List/AgentKeyMonitor.swift
// Kronos v1.2 Phase 2 slice C3: a SECOND, independent path to AgentKeyActions, parallel to the
// `.onKeyPress(characters:)` handling in TaskListScreen.swift. `NSWindow.sendEvent` tries
// `performKeyEquivalent` first for any Command-held keyDown; a POSTED (not real-hardware) event
// does not reliably continue past that to the normal responder chain in the live UI test — the
// same class of limitation `OptionChordMonitor.swift` documents for Option-held menu chords,
// here affecting every Command-held chord's onKeyPress delivery (with or without Control): the
// live test proved all three of ⌃⌘H / ⌃⇧⌘H / ⌘. never reach TaskListScreen's onKeyPress closure
// at all (a DBG diagnostic placed at its very first line never fired). A local key monitor
// catches the keyDown directly and calls the exact same AgentKeyActions the onKeyPress path
// calls, so the two paths can never drift. List-scope only (HotkeyRegistry's own scope for
// these three ids): stands down while Flow or Board show instead, which own their separate
// H / ⇧H / ⌘. handling for their own screens.
import AppKit
import KronosCore

@MainActor
enum AgentKeyMonitor {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event) ? nil : event
        }
    }

    private static func handle(_ event: NSEvent) -> Bool {
        guard let model = AppDelegate.shared?.model,
              let key = NSApp.keyWindow ?? NSApp.mainWindow, !(key is NSPanel), key.title == "Kronos",
              !(key.firstResponder is NSTextView),
              model.options(for: model.scope).layout == .list
        else { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers?.lowercased()
        if chars == "h", mods == [.control, .command] {
            AgentKeyActions.handoff(model, andRun: false)
            return true
        }
        if chars == "h", mods == [.control, .command, .shift] {
            AgentKeyActions.handoff(model, andRun: true)
            return true
        }
        if chars == ".", mods == .command {
            AgentKeyActions.stopSelectedRun(model)
            return true
        }
        return false
    }
}
