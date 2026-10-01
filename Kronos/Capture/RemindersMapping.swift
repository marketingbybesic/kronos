// Kronos/Capture/RemindersMapping.swift
// The pure part of "From Reminders": one open reminder as plain data, and the rules that turn it
// into a proposed task. Foundation only, so scripts/reminders-selftest.swift compiles the real
// file (EventKit itself lives in RemindersSource.swift).
import Foundation

struct ReminderItem: Equatable, Sendable {
    var title: String
    var notes: String?
    /// The due date, if the reminder has one. Only the calendar day matters to Kronos.
    var due: Date?
    /// The Reminders list the item lives in ("Groceries"): becomes the project when a project
    /// of that name exists.
    var listName: String
}

enum RemindersMapping {
    /// The existing project whose name equals `listName` ignoring case, diacritics and
    /// surrounding spaces. Nil when there is none: a list never creates a project on its own.
    static func matchProject(listName: String, projectNames: [String]) -> String? {
        let key = fold(listName)
        guard !key.isEmpty else { return nil }
        return projectNames.first { fold($0) == key }
    }

    /// Titles are trimmed and collapsed onto one line; notes are trimmed and dropped when blank.
    static func cleaned(_ item: ReminderItem) -> ReminderItem? {
        let title = item.title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !title.isEmpty else { return nil }
        let notes = item.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ReminderItem(title: title, notes: (notes?.isEmpty ?? true) ? nil : notes,
                            due: item.due, listName: item.listName.trimmingCharacters(in: .whitespaces))
    }

    /// Cleaned items in a stable order: dated reminders first (soonest first), then the undated
    /// ones in the order Reminders returned them. Blank titles are dropped.
    static func ordered(_ items: [ReminderItem]) -> [ReminderItem] {
        let cleaned = items.compactMap(cleaned)
        let dated = cleaned.enumerated().filter { $0.element.due != nil }
            .sorted { ($0.element.due!, $0.offset) < ($1.element.due!, $1.offset) }.map(\.element)
        return dated + cleaned.filter { $0.due == nil }
    }

    private static func fold(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
