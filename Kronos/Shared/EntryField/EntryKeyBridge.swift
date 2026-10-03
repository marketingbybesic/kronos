// Kronos/Shared/EntryField/EntryKeyBridge.swift
// The AppKit half of the entry field, placed as the `.background` of its `TextEditor`:
//   - finds the field's own NSTextView (the one under this view, not the first in the window),
//     switches off the system text substitutions that would rewrite `#`, `>` and `-` syntax,
//     and reports the caret to the model;
//   - runs ONE local key monitor that acts only while that text view is the key window's first
//     responder (never a container `.onKeyPress`, which fires while a field inside it types):
//       list open:  Up/Down move, Tab takes the highlighted suggestion, Return takes it when the
//                   typed name is not complete yet (else it submits), Esc closes the list only;
//       always:     Return submits (`.clear`), Command-Return submits (`.stay`), Option-Return
//                   submits keeping the pills (`.keepPills`), Shift-Return is left alone (a new
//                   line), Backspace in an empty field removes the last pill.
// What a mode means is the host's call: the global quick add panel closes on `.clear` and stays
// open on `.stay` / `.keepPills`; every other surface treats `.stay` exactly like `.clear`.
// Keys are matched by what they ARE (`specialKey`, the produced character), never by a
// physical key code, so a Croatian or any other layout behaves the same.
import SwiftUI
import AppKit

enum EntrySubmitMode {
    /// Return: add, then empty the field (text and pills). The quick add panel also closes.
    case clear
    /// Command-Return: add, then empty the field and keep going. Only the quick add panel
    /// tells this apart from `.clear` (it stays open); other surfaces treat it as `.clear`.
    case stay
    /// Option-Return: add, then empty only the text; the pills stay for the next entry.
    case keepPills

    /// The mode a Return chord asks for, or nil for Shift-Return (a new line). Option wins
    /// over Command: Option-Command-Return keeps the pills.
    static func forReturn(_ mods: NSEvent.ModifierFlags) -> EntrySubmitMode? {
        if mods.contains(.shift) { return nil }
        if mods.contains(.option) { return .keepPills }
        if mods.contains(.command) { return .stay }
        return .clear
    }
}

struct EntryKeyBridge: NSViewRepresentable {
    let model: EntryFieldModel
    /// A restored draft opens fully selected, so typing replaces it.
    var selectAllOnAppear = false
    var onSubmit: (EntrySubmitMode) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.parent = self
        DispatchQueue.main.async { [weak coordinator = context.coordinator] in
            coordinator?.installMonitor()
            coordinator?.attachWithRetry()
        }
        if selectAllOnAppear {
            // After SwiftUI's own focus grab (asyncAfter, not async), or it would reset the selection.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak coordinator = context.coordinator] in
                guard let tv = coordinator?.textView else { return }
                tv.window?.makeFirstResponder(tv)
                tv.selectAll(nil)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
        DispatchQueue.main.async { [weak coordinator = context.coordinator] in coordinator?.attach() }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.teardown() }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var parent: EntryKeyBridge?
        weak var view: NSView?
        weak var textView: NSTextView?
        private var monitor: Any?
        private var selectionObserver: NSObjectProtocol?

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        }

        func teardown() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
            selectionObserver = nil
            if parent?.model.textView === textView { parent?.model.textView = nil }
        }

        /// The TextEditor's text view may not exist yet in the first layout pass: look again a few times.
        func attachWithRetry(_ attempt: Int = 0) {
            attach()
            guard textView == nil, attempt < 8 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.attachWithRetry(attempt + 1) }
        }

        /// The text view whose frame overlaps this view's the most, searching outward from it,
        /// so two fields in one window never get each other's text view.
        func attach() {
            guard let view, let window = view.window, let model = parent?.model else { return }
            if textView == nil {
                let mine = view.convert(view.bounds, to: nil)
                var best: (NSTextView, CGFloat)?
                var ancestor = view.superview
                while let a = ancestor, best == nil {
                    for tv in a.entryTextViews {
                        let r = tv.convert(tv.bounds, to: nil).intersection(mine)
                        let area = r.isNull ? 0 : r.width * r.height
                        if area > 0, area > (best?.1 ?? 0) { best = (tv, area) }
                    }
                    ancestor = a.superview
                }
                guard let tv = best?.0 else { return }
                textView = tv
                model.textView = tv
                selectionObserver = NotificationCenter.default.addObserver(
                    forName: NSTextView.didChangeSelectionNotification, object: tv, queue: .main
                ) { [weak self, weak tv] _ in
                    MainActor.assumeIsolated {
                        guard let self, let tv, let model = self.parent?.model else { return }
                        let r = tv.selectedRange()
                        model.setCaret(r.location + r.length, hasSelection: r.length > 0)
                    }
                }
                let r = tv.selectedRange()
                model.setCaret(r.location + r.length, hasSelection: r.length > 0)
            }
            if let tv = textView {
                tv.isAutomaticDashSubstitutionEnabled = false
                tv.isAutomaticQuoteSubstitutionEnabled = false
                tv.isAutomaticTextReplacementEnabled = false
                tv.isAutomaticSpellingCorrectionEnabled = false
            }
            _ = window
        }

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                // Local monitors run on the main thread; the event never leaves it.
                nonisolated(unsafe) let e = event
                let used = MainActor.assumeIsolated { self.handle(e) }
                return used ? nil : event
            }
        }

        /// True when the event was used here.
        func handle(_ event: NSEvent) -> Bool {
            guard let parent, let tv = textView, let window = tv.window,
                  event.window === window, window.isKeyWindow, window.firstResponder === tv,
                  !tv.hasMarkedText() else { return false }
            let model = parent.model
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])

            // What the key IS: the special key it produced, falling back to the produced
            // character (a synthetic event carries characters but may carry no key code).
            let chars = event.charactersIgnoringModifiers ?? ""
            let special = event.specialKey
            let isReturn = special == .carriageReturn || special == .enter || chars == "\r" || chars == "\u{3}"
            let isTab = special == .tab || chars == "\t"
            let isBackspace = special == .delete || chars == "\u{7F}"

            if mods.isEmpty, model.isListOpen, special == .upArrow { model.move(-1); return true }
            if mods.isEmpty, model.isListOpen, special == .downArrow { model.move(1); return true }
            if mods.isEmpty, model.isListOpen, isTab { model.acceptSelected(); return true }
            if isReturn {
                // Shift-Return is a new line (outline subtasks); everything else is "add".
                guard let mode = EntrySubmitMode.forReturn(mods) else { return false }
                // Plain Return takes a highlighted, unfinished #/@ name first.
                if mode == .clear, mods.isEmpty, model.isListOpen && model.returnAccepts { model.acceptSelected(); return true }
                parent.onSubmit(mode)
                return true
            }
            if mods.isEmpty, isBackspace, tv.string.isEmpty, !model.pills.isEmpty {
                return model.removeLastPill()
            }
            if mods.isEmpty, event.keyCode == 53 || event.charactersIgnoringModifiers == "\u{1B}" {
                return model.closeList()
            }
            return false
        }
    }
}

extension NSView {
    /// Every NSTextView below this view (not including a text view inside another window).
    var entryTextViews: [NSTextView] {
        var found: [NSTextView] = []
        func walk(_ v: NSView) {
            if let tv = v as? NSTextView { found.append(tv) }
            for s in v.subviews { walk(s) }
        }
        walk(self)
        return found
    }
}
