// Kronos/Triage/TriageKeys.swift. Split out of TriageFlowView.swift (500-line lint gate).
//
// ROOT CAUSE of a real bug where Return/Tab did nothing live: the card grabbed focus with
// `isFocused = true` SYNCHRONOUSLY inside `.onAppear`. AppShellView keeps `TaskListScreen`
// mounted and focusable underneath every overlay (it is never removed from the ZStack, only
// visually covered), so at the instant the card appears the list's own `.focusable(true)` row
// still holds first responder; a same-tick `isFocused = true` loses that race and the keys keep
// going to the list. A deferred focus narrowed the race but did not close it: `.onKeyPress` /
// `@FocusState` only deliver a key if THIS view's focusable container is the one SwiftUI
// resolved to first responder, and menu popovers reassign first responder inside AppKit
// without ever touching SwiftUI's FocusState (every open/close of the priority / effort /
// deadline / project KMenuButton on this same card). `.onKeyPress` is SwiftUI-focus-gated by
// construction, so no ordering fix inside SwiftUI can make it robust here. Fixed by bypassing
// SwiftUI focus for key dispatch: an `NSEvent.addLocalMonitorForEvents(.keyDown)` installed
// while the card is on screen (TriageKeyCatcher), the same pattern the palette's `KeyCatcher`
// proves live in the same ZStack.
import SwiftUI
import KronosCore

extension TriageFlowView {

    /// One dispatch point for every key the card's hint rows advertise, fed by the NSEvent
    /// monitor (which already restricted delivery to this card's own key window).
    /// `event.charactersIgnoringModifiers` (not `.characters`) so Shift-driven caps or dead
    /// keys never desync a letter shortcut from what the hint row prints. Returns true when
    /// the key was consumed (the monitor then swallows it), false to let it fall through to
    /// whatever AppKit would otherwise have done with it (real typing in a text field, or a
    /// menu-bar command like Cmd-W).
    func handleKey(_ event: NSEvent) -> Bool {
        // STACKING GUARD: triage shares one NSWindow with every other AppShellView overlay
        // (triage=61 < timeBlocks=71 < impuls=80 < capture=89 < palette=98 in the ZStack), so
        // the window check alone does not tell this card whether it is the TOPMOST one on
        // screen. Any overlay that can render above it owns the keyboard while it is open;
        // so does the shortcuts card (topmost).
        guard !model.isTimeBlocksOpen, !model.isImpulsOpen, !model.isCaptureOpen, !model.isPaletteOpen, !model.isKeymapOpen else {
            return false
        }
        // The "Finish <B> first" card is modal above everything: its own keys (B, Esc, Return) belong to it.
        guard model.pendingBlockedCompletion == nil else { return false }
        // PICKER GUARD: the project picker popover has its own field and key handling (arrows, Return, Esc);
        // while it is open none of the card's keys act, or Return would also accept the card.
        guard !isPickingProject else { return false }
        // MODIFIER GUARD: Cmd/Ctrl/Opt turn a plain letter into an unrelated menu command
        // (Cmd-W close window, Cmd-Q quit, Cmd-Z undo, Cmd-K palette, …); none of this card's
        // shortcuts are meant to fire with a modifier held. Shift alone is fine.
        let blockingModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        let heldModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Review owns one chord: Command-Return approves the whole proposal.
        let isReviewApproveAll = isReview && event.keyCode == 36 && heldModifiers.contains(.command)
            && heldModifiers.isDisjoint(with: [.control, .option])
        guard heldModifiers.isDisjoint(with: blockingModifiers) || isReviewApproveAll else {
            return false
        }
        // TEXT-FIELD GUARD: any text view that has the keyboard (the date or first-move field)
        // owns plain characters; only Return/Esc/Tab are ever card-owned while typing.
        let isTypingAnywhereOnCard = (event.window?.firstResponder) is NSTextView
        let isEditingText = isEditingDate || isEditingMove
        if isTypingAnywhereOnCard, !isEditingText {
            switch event.keyCode {
            case 36, 76, 53, 48: break // Return / keypad Return / Esc / Tab: fall through below.
            default: return false
            }
        }
        if isEditingText {
            // The field owns its characters; only Return (commit) and Esc (cancel) apply.
            switch event.keyCode {
            case 36, 76:
                guard let current else { return false }
                if isEditingMove { commitMove(for: current) } else { commitTypedDate(for: current) }
                return true
            case 53:
                isEditingDate = false
                isEditingMove = false
                return true
            default:
                return false // Tab and every character key stay in the text field.
            }
        }
        if sessionOver {
            // Five cards done: Return starts the next sitting, Esc closes, nothing else acts.
            switch event.keyCode {
            case 36, 76: continueSession(); return true
            case 53: onClose(); return true
            default: return false
            }
        }
        if isReview { return handleReviewKey(event) || swallowsUnbound(event) }
        switch event.keyCode {
        case 36, 76: acceptAndNext(); return true // Return / keypad Return
        case 48: skip(); return true              // Tab
        case 53: onClose(); return true           // Esc
        default: break
        }
        return (isSweep ? handleSweepKey(event) : handleSortKey(event)) || swallowsUnbound(event)
    }

    /// The card is modal: a plain letter, digit or punctuation key it does not use must not reach
    /// the list underneath, where the same grammar would act on a row the person is not looking at.
    /// Arrows, Return and other named keys keep their normal route.
    private func swallowsUnbound(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isDisjoint(with: [.command, .control, .option]),
              let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first,
              event.charactersIgnoringModifiers?.unicodeScalars.count == 1 else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || CharacterSet.punctuationCharacters.contains(scalar)
            || CharacterSet.symbols.contains(scalar)
    }


    /// The grammar action a key press means on this card (TriageKeyGrammar.swift), read from the
    /// registry bindings the list uses, so a rebound key moves on both.
    private func grammarAction(_ event: NSEvent, _ context: TriageKeyContext) -> TriageKeyAction? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return TriageKeyGrammar.action(characters: event.charactersIgnoringModifiers ?? "",
                                       keyCode: event.keyCode, shift: flags.contains(.shift),
                                       command: flags.contains(.command), option: flags.contains(.option),
                                       control: flags.contains(.control), context: context,
                                       bindings: { HotkeyRegistry.current(for: $0) })
    }

    /// The field keys of the sort card, for the Review card while its fields are open: priority,
    /// effort, date and project only (no plan, park, delete, done or AI refresh).
    func handleEditKey(_ event: NSEvent) -> Bool {
        guard let action = grammarAction(event, .reviewEdit) else { return false }
        performSortAction(action)
        return true
    }

    /// The sort card's grammar: every key the list knows, plus E (first move), N (no deadline)
    /// and R (ask the AI again), which never block the other keys.
    private func handleSortKey(_ event: NSEvent) -> Bool {
        guard let action = grammarAction(event, .sort) else { return false }
        performSortAction(action)
        return true
    }

    /// Sweep keys: T plan today, Y someday, ⌫ delete, Space done. Return keeps (above).
    private func handleSweepKey(_ event: NSEvent) -> Bool {
        guard let action = grammarAction(event, .sweep) else { return false }
        switch action {
        case .planToday: sweep(.planToday)
        case .someday: sweep(.someday)
        case .delete: sweep(.delete)
        case .done: sweep(.done)
        default: return false
        }
        return true
    }
}
