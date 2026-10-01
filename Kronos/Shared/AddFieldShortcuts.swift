// Kronos/Shared/AddFieldShortcuts.swift
// Two chords that must work INSIDE a multi-line add field (Capture paste, quick add, the menu-bar
// capture field), where an ancestor `.onKeyPress` or a menu item never gets the event:
//   - Cmd-Return  -> the field's primary action ("Find tasks"). A `TextEditor` is an `NSTextView`;
//     SwiftUI never forwards its Cmd-Return to a parent's `.onKeyPress`, so the hint "Cmd Return to
//     find tasks" was shown while the chord did nothing. A local key monitor, acting only while the
//     text view under THIS field is the first responder, takes it before the text view does.
//   - the Capture chord (Shift-Cmd-N by default) -> insert the subtask marker `>` at the caret
//     (`SubtaskMarker` in Core decides the exact text) and flash a short confirmation. With no add
//     field focused the same chord still opens Capture, through the menu item in KronosApp.
// The menu item calls `SubtaskMarkerShortcut.insertIntoFocusedField()` first; the monitor covers the
// panel that sits over another app (quick add), where the app's menu bar is not in play.
// "Focused" is read from AppKit (the first responder's text view sits inside this field's frame),
// not from a SwiftUI FocusState, which a field nested inside another focus scope does not report.
import SwiftUI
import AppKit
import KronosCore

@MainActor
final class AddFieldCoordinator {
    let id = UUID()
    weak var view: NSView?
    var monitor: Any?
    var marker = false
    var onCommandReturn: (() -> Void)?
    var onInserted: (() -> Void)?

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

@MainActor
enum SubtaskMarkerShortcut {
    private static var fields: [UUID: AddFieldCoordinator] = [:]

    static func register(_ coordinator: AddFieldCoordinator) { fields[coordinator.id] = coordinator }
    static func unregister(_ coordinator: AddFieldCoordinator) { fields[coordinator.id] = nil }

    /// True when `event` is the Capture chord in its CURRENT binding (the person may have rebound it).
    static func matches(_ event: NSEvent) -> Bool {
        guard let binding = HotkeyRegistry.current(for: "window.capture") else { return false }
        var want: NSEvent.ModifierFlags = []
        if binding.shift { want.insert(.shift) }
        if binding.option { want.insert(.option) }
        if binding.control { want.insert(.control) }
        if binding.command { want.insert(.command) }
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == want,
              let typed = event.charactersIgnoringModifiers?.lowercased() else { return false }
        return typed == binding.key
    }

    /// Inserts the marker at the caret of the focused add field. False when no add field has focus
    /// (the caller then does the chord's normal job).
    @discardableResult
    static func insertIntoFocusedField() -> Bool {
        for coordinator in fields.values where coordinator.marker {
            guard let textView = coordinator.focusedTextView else { continue }
            let text = textView.string as NSString
            let selection = textView.selectedRange()
            guard selection.location != NSNotFound, selection.location + selection.length <= text.length else { return false }
            let marker = SubtaskMarker.insertion(before: Substring(text.substring(to: selection.location)),
                                                 after: Substring(text.substring(from: selection.location + selection.length)))
            textView.insertText(marker, replacementRange: selection)
            coordinator.onInserted?()
            return true
        }
        return false
    }
}

/// Local key monitor tied to ONE field. Acts only while that field's text view is first responder;
/// every other key passes through untouched.
private struct AddFieldKeys: NSViewRepresentable {
    let marker: Bool
    let onCommandReturn: (() -> Void)?
    let onInserted: () -> Void

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
                if coordinator.marker, SubtaskMarkerShortcut.matches(event) {
                    return SubtaskMarkerShortcut.insertIntoFocusedField()
                }
                return false
            }
            return handled ? nil : event
        }
        SubtaskMarkerShortcut.register(coordinator)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.marker = marker
        coordinator.onCommandReturn = onCommandReturn
        coordinator.onInserted = onInserted
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: AddFieldCoordinator) {
        SubtaskMarkerShortcut.unregister(coordinator)
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

/// The confirmation shown for a moment after the marker is inserted.
struct SubtaskMarkerFlash: View {
    var body: some View {
        Text(String(localized: "quickadd.marker_added"))
            .font(Typo.meta)
            .foregroundStyle(Tok.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, Space.x2)
            .padding(.vertical, Space.x1)
            .background(Tok.controlFill)
            .clipShape(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
            .accessibilityIdentifier("subtask.marker.flash")
            .uiTestAnchor("subtask.marker.flash")
    }
}

private struct AddFieldBehaviour: ViewModifier {
    let marker: Bool
    let onCommandReturn: (() -> Void)?
    @State private var flashToken = 0
    @State private var isFlashing = false

    func body(content: Content) -> some View {
        content
            .background(AddFieldKeys(marker: marker, onCommandReturn: onCommandReturn, onInserted: flash))
            .overlay(alignment: .bottomTrailing) {
                if isFlashing {
                    SubtaskMarkerFlash().padding(Space.x2).transition(.opacity)
                }
            }
    }

    private func flash() {
        flashToken += 1
        let token = flashToken
        withAnimation(Motion.hover) { isFlashing = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            guard token == flashToken else { return }
            withAnimation(Motion.hover) { isFlashing = false }
        }
    }
}

extension View {
    /// Wires an add field's own chords (see the file header). `marker` turns on the subtask-marker
    /// chord and its confirmation; `onCommandReturn` is the field's primary action.
    func addFieldBehaviour(marker: Bool = false, onCommandReturn: (() -> Void)? = nil) -> some View {
        modifier(AddFieldBehaviour(marker: marker, onCommandReturn: onCommandReturn))
    }
}
