// Kronos/Triage/ReviewNextKeys.swift
// Review next's own single-key grammar (Kronos v1.2 Phase 2 slice D2): A approve, X request
// changes, S skip, Space expands the agent-done run glance (ReviewNextRunSection.swift), ⇧A
// approves every other pending item from the same agent. An NSEvent local monitor, not SwiftUI
// `.onKeyPress`/`@FocusState` — same root cause TriageKeys.swift documents (a menu popover
// reassigning first responder never touches SwiftUI's FocusState) — so this card reuses that
// file's own `TriageKeyCatcher` rather than a second NSView wrapper.
import AppKit
import SwiftUI

extension ReviewNextView {
    func handleKey(_ event: NSEvent) -> Bool {
        // Every sibling overlay that can render ABOVE ReviewNext in AppShellView's own ZStack
        // owns the keyboard while it is open (Triage sits BELOW it there, so it is not checked).
        guard !model.isTimeBlocksOpen, !model.isImpulsOpen, !model.isCaptureOpen, !model.isPaletteOpen,
              !model.isKeymapOpen, model.pendingBlockedCompletion == nil else { return false }
        let blockingModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        let heldModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard heldModifiers.isDisjoint(with: blockingModifiers) else { return false }
        // The note field owns its own characters (and its own Return/Esc via .onSubmit/
        // .onExitCommand already on `noteField`); this monitor never touches a key while it —
        // or any other text view — has the keyboard.
        guard !isRequestingChanges, !((event.window?.firstResponder) is NSTextView) else { return false }
        guard let item = current else { return false }
        if event.keyCode == 49 { isRunExpanded.toggle(); return true }   // Space
        // Shift is read from the flag, never from the letter's case (TriageKeyGrammar.swift's
        // own rule): Caps Lock alone still produces "A" from `charactersIgnoringModifiers`, and
        // without this a Caps Lock user pressing plain A would approve every pending item from
        // the agent instead of just the one on screen.
        let shiftHeld = heldModifiers.contains(.shift)
        switch (event.charactersIgnoringModifiers ?? "").lowercased() {
        case "a":
            if shiftHeld { approveAllFromAgent(item) } else { approve(item) }
            return true
        case "x":
            isRequestingChanges = true
            noteText = ""
            DispatchQueue.main.async { isNoteFocused = true }
            return true
        case "s": advance(); return true
        default: return swallowsUnbound(event)
        }
    }

    /// The card is modal (AppShellView's scrim covers the list beneath it): a plain letter,
    /// digit or punctuation key this grammar does not use must not reach the list underneath —
    /// same reasoning as TriageKeys.swift's own `swallowsUnbound`.
    private func swallowsUnbound(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isDisjoint(with: [.command, .control, .option]),
              let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first,
              event.charactersIgnoringModifiers?.unicodeScalars.count == 1 else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || CharacterSet.punctuationCharacters.contains(scalar)
            || CharacterSet.symbols.contains(scalar)
    }
}
