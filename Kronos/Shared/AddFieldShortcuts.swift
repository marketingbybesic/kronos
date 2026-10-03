// Kronos/Shared/AddFieldShortcuts.swift
// Cmd-Return inside a multi-line add field (Capture paste, the menu-bar capture field), where an
// ancestor `.onKeyPress` or a menu item never gets the event: it runs the field's primary action
// ("Find tasks"). A `TextEditor` is an `NSTextView`; SwiftUI never forwards its Cmd-Return to a
// parent's `.onKeyPress`, so the hint "Cmd Return to find tasks" was shown while the chord did
// nothing. A local key monitor, acting only while the text view under THIS field is the first
// responder, takes it before the text view does.
// The Capture chord (Shift-Cmd-N by default) has ONE meaning everywhere: open Capture. A subtask
// line in an add field starts with Shift-Return (see EntryField), never with that chord.
// "Focused" is read from AppKit (the first responder's text view sits inside this field's frame),
// not from a SwiftUI FocusState, which a field nested inside another focus scope does not report.
import SwiftUI
import AppKit

@MainActor
final class AddFieldCoordinator {
    weak var view: NSView?
    var monitor: Any?
    var onCommandReturn: (() -> Void)?

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    /// The text view that has keyboard focus when it lies inside this field's frame.
    var focusedTextView: NSTextView? {
        guard let view, let window = view.window,
              let textView = window.firstResponder as? NSTextView, textView.isEditable, window.isKeyWindow else { return nil }
        let field = view.convert(view.bounds, to: nil)
        let text = textView.convert(textView.bounds, to: nil)
        return field.contains(CGPoint(x: text.midX, y: text.midY)) ? textView : nil
    }
}

/// Local key monitor tied to ONE field. Acts only while that field's text view is first responder;
/// every other key passes through untouched.
private struct AddFieldKeys: NSViewRepresentable {
    let onCommandReturn: (() -> Void)?

    func makeCoordinator() -> AddFieldCoordinator { AddFieldCoordinator() }

    func makeNSView(context: Context) -> NSView {
        let coordinator = context.coordinator
        let view = NSView()
        coordinator.view = view
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator] event in
            guard let coordinator else { return event }
            let handled: Bool = MainActor.assumeIsolated {
                guard coordinator.focusedTextView != nil else { return false }
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if (event.keyCode == 36 || event.keyCode == 76), flags == .command, let action = coordinator.onCommandReturn {
                    action()
                    return true
                }
                return false
            }
            return handled ? nil : event
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onCommandReturn = onCommandReturn
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: AddFieldCoordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor); coordinator.monitor = nil }
    }
}

/// Cmd-Return for a whole screen (Capture): takes the chord whichever control has focus, because
/// once a step swaps its views the first responder can be nothing a SwiftUI `.onKeyPress` listens
/// to (after "Find tasks" the paste field is gone and Cmd-Return on the review step went nowhere).
/// Stands down while a sheet (the Notes picker) is open over the screen.
struct CommandReturnMonitor: NSViewRepresentable {
    let action: () -> Void

    final class Coordinator {
        var monitor: Any?
        var action: () -> Void = {}
        weak var view: NSView?
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let coordinator = context.coordinator
        let view = NSView()
        coordinator.view = view
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator] event in
            guard event.keyCode == 36 || event.keyCode == 76,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return event }
            guard let coordinator, let window = coordinator.view?.window, window.isKeyWindow, window.attachedSheet == nil,
                  event.window === window else { return event }
            coordinator.action()
            return nil
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.action = action }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor); coordinator.monitor = nil }
    }
}

extension View {
    /// Wires an add field's own chord (see the file header): `onCommandReturn` is the field's primary action.
    func addFieldBehaviour(onCommandReturn: @escaping () -> Void) -> some View {
        background(AddFieldKeys(onCommandReturn: onCommandReturn))
    }
}
