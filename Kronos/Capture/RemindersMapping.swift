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
    /// The Reminders item's own identifier (stable on this Mac). Empty when the source gave none;
    /// such an item can never be recognised again and is always offered.
    var id: String = ""
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
                            due: item.due, listName: item.listName.trimmingCharacters(in: .whitespaces),
                            id: item.id)
    }

    // MARK: Origin stamp and re-import

    /// What a task made from a reminder carries in `source`.
    static let originSource = "reminders"

    /// The `externalID` stamped on a task made from a reminder; nil when the reminder has no id.
    static func externalID(for item: ReminderItem) -> String? {
        item.id.isEmpty ? nil : originSource + ":" + item.id
    }

    /// The reminders that are not yet a task: an item whose stamped id is in `known` is skipped, an
    /// item without an id is always kept. Order is untouched.
    static func fresh(_ items: [ReminderItem], knownExternalIDs known: Set<String>) -> [ReminderItem] {
        items.filter { item in
            guard let key = externalID(for: item) else { return true }
            return !known.contains(key)
        }
    }

    /// Which reminder a just-created task came from: the first unclaimed item whose cleaned title
    /// equals the task's title (case and diacritics ignored). Nil when none matches, for instance
    /// after the title was edited in the review step; that task simply is not stamped.
    static func matchOrigin(taskTitle: String, in items: [ReminderItem], claimed: Set<String>) -> ReminderItem? {
        let key = fold(taskTitle)
        guard !key.isEmpty else { return nil }
        return items.first { item in
            guard let ext = externalID(for: item), !claimed.contains(ext) else { return false }
            return fold(cleaned(item)?.title ?? "") == key
        }
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
