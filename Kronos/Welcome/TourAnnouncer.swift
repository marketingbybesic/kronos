// Kronos/Welcome/TourAnnouncer.swift
// The tour speaks each step. The bubble appears over a window the person is not looking at with
// VoiceOver's cursor, so on every step (and when the tour opens) the step is announced as one
// sentence: "<n> of <total>. <title>. <body>". The text is kept in `last` so a live test can
// read what was said without a screen reader running.
import AppKit

@MainActor
enum TourAnnouncer {
    /// The most recent announcement, for the live test.
    private(set) static var last = ""

    static func announce(position: String, title: String, body: String) {
        let text = [position, title, body].filter { !$0.isEmpty }.joined(separator: ". ")
        last = text
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}
