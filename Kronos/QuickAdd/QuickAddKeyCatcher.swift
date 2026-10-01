// Kronos/QuickAdd/QuickAddKeyCatcher.swift
// Split out of QuickAddPanelView.swift (500-line cap): the Return catcher + NSTextView helpers.
import SwiftUI
import AppKit

/// Local NSEvent monitor scoped to this view's lifetime, same pattern as
/// `Kronos/Palette/CommandPaletteView.swift`'s `KeyCatcher`: SwiftUI's `.onSubmit`/`.onKeyPress`
/// do not fire for a `TextEditor` (multi-line editors have no "submit" concept — every Return
/// is just a newline to them), so plain Return has to be caught here and routed to `onReturn`;
/// Option-Return and Shift-Return are let through untouched, which is what makes `TextEditor`
/// insert its normal newline, so Return can be used to write a subtask line instead of
/// sending the whole thing.
///
/// ROOT CAUSE of a real bug where the quick add did not add subtasks properly:
/// `TextEditor`'s backing `NSTextView` inherits macOS's system-wide smart-substitution defaults
/// (System Settings > Keyboard > Text Input — on by default on a real Mac, off in a snapshot's
/// bare process, which is why `QuickAddSnapshots`' seeded outline always rendered fine). With
/// dash/text substitution on, a line typed as `- find the template` can be silently rewritten
/// (en-dash, or a registered text replacement) before `TaskOutline.parse` ever sees it, and the
/// line no longer starts with a marker `dissect` recognises — the panel path "loses" subtasks
/// the deterministic `ListInlineNewTaskRow`/Capture paths never touch because neither uses a
/// freeform multi-line `NSTextView`. Same view is reused to reach the real `NSTextView` (there is
/// exactly one in this panel) and turn every macOS text substitution off, the way a command-line
/// / quick-entry field should behave — never touched here otherwise, so nothing about typing
/// speed or focus changes.
struct QuickAddKeyCatcher: NSViewRepresentable {
    let onReturn: () -> Void
    /// A restored draft opens fully selected, so typing replaces it (one restore, one Cmd-A saved).
    var selectAllOnAppear = false

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        if selectAllOnAppear {
            // After SwiftUI's own focus grab (asyncAfter, not async), or it would reset the selection.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                guard let textView = view.window?.contentView?.qaFirstTextView else { return }
                view.window?.makeFirstResponder(textView)
                textView.selectAll(nil)
            }
        }
        DispatchQueue.main.async { [weak view] in
            guard let view else { return }
            context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view] event in
                let isReturn = event.keyCode == 36 || event.keyCode == 76
                let plainReturn = isReturn && event.modifierFlags.isDisjoint(with: [.option, .shift])
                // ROOT CAUSE of "Cmd-Return (and plain Return) does nothing in the main window after
                // quick add was used once": closing the panel only hides it, so its hosting view, and
                // this monitor, lived on and swallowed every Return in the whole app, calling `submit`
                // of a hidden panel. Act only for events delivered to the panel's own window.
                guard plainReturn, let window = view?.window, event.window === window, window.isKeyWindow else { return event }
                onReturn()
                return nil
            }
            disableSmartSubstitution(in: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { disableSmartSubstitution(in: nsView) }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Walks up to the window and finds the panel's `NSTextView` (there is only one), then turns
    /// off every substitution that would rewrite `TaskOutline`/`QuickAddParser` syntax before it
    /// is read. Idempotent and cheap enough to call on every update.
    private func disableSmartSubstitution(in view: NSView) {
        guard let textView = view.window?.contentView?.qaFirstTextView else { return }
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
    }

    final class Coordinator {
        var monitor: Any?
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

extension NSView {
    /// Depth-first search for the first `NSTextView` descendant.
    var qaFirstTextView: NSTextView? {
        if let textView = self as? NSTextView { return textView }
        for sub in subviews {
            if let found = sub.qaFirstTextView { return found }
        }
        return nil
    }
}
