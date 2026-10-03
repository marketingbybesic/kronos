// Kronos/List/ListPillAnnouncer.swift
// VoiceOver hears every undo pill and notice: whatever screen raised it, the message (and, when
// the pill offers a primary action, how to take it) is posted as an announcement the moment the
// pill appears. Attached once, to the list screen, which is mounted for the life of the window.
import SwiftUI
import KronosCore

@MainActor
enum ListPillAnnouncer {
    /// The last text announced; the live UI test reads it (VoiceOver itself cannot be observed).
    private(set) static var lastAnnouncement: String?

    static func text(for state: ListUndoState) -> String {
        guard state.primaryTitle != nil else { return state.message }
        return state.message + " " + String(localized: "undo.donenext.a11y.hint")
    }

    static func announce(_ state: ListUndoState?) {
        guard let state else { return }
        let text = text(for: state)
        lastAnnouncement = text
        AccessibilityNotification.Announcement(text).post()
    }
}

private struct PillAnnouncement: ViewModifier {
    func body(content: Content) -> some View {
        content.onChange(of: UndoToastCenter.shared.current?.id) { _, id in
            guard id != nil else { return }
            ListPillAnnouncer.announce(UndoToastCenter.shared.current)
        }
    }
}

extension View {
    /// Announces each new undo pill or notice to VoiceOver.
    func announcesUndoPills() -> some View { modifier(PillAnnouncement()) }
}
