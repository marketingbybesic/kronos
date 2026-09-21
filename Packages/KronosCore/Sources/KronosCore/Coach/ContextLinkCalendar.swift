// Coach/ContextLinkCalendar.swift — a task can be linked to one calendar event, so the
// inspector can show which time block it belongs to. Encoded as its own `cal://` line in the
// task's notes text — same mechanism and file family as `NoteLink`'s `notes://` and
// `ContextLink`'s `link://`, but independent of both: a task can carry a note link, a context
// link AND a calendar link at once (three separate control lines), unlike NoteLink/ContextLink
// which each replace their own single line.
import Foundation

/// A task linked to one calendar event (`KCalendarEvent.id`) plus enough of the event to show
/// it without re-fetching from EventKit (event data is read-only and time-bounded — the
/// inspector renders straight from the events `CoachModel.todaysBlocks` already loaded, then
/// falls back to this cached title/time if the event has since scrolled out of "today").
public struct TaskCalendarLink: Equatable, Sendable {
    public let eventID: String
    public let title: String
    public let start: Date
    public let end: Date

    public init(eventID: String, title: String, start: Date, end: Date) {
        self.eventID = eventID
        self.title = title
        self.start = start
        self.end = end
    }

    private static let scheme = "cal://"

    /// One `cal://<eventID>|<title>|<startEpoch>|<endEpoch>` line. `|` in `title` is
    /// percent-escaped exactly like `ContextLink.encodedLine`, for the same reason (it is the
    /// field separator).
    public var encodedLine: String {
        "\(Self.scheme)\(eventID)|\(Self.escape(title))|\(start.timeIntervalSince1970)|\(end.timeIntervalSince1970)"
    }

    /// The first `cal://` line's link, or nil when absent or malformed.
    public static func find(in notesText: String) -> TaskCalendarLink? {
        for rawLine in notesText.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(scheme) else { continue }
            let body = String(trimmed.dropFirst(scheme.count))
            let parts = body.components(separatedBy: "|")
            guard parts.count == 4, let start = Double(parts[2]), let end = Double(parts[3]) else { continue }
            return TaskCalendarLink(eventID: parts[0], title: unescape(parts[1]),
                                    start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end))
        }
        return nil
    }

    /// Appends this link to `notesText`, replacing any existing `cal://` line — a task links
    /// to at most one block at a time.
    public func appending(to notesText: String) -> String {
        let withoutExisting = Self.removing(from: notesText)
        return withoutExisting.isEmpty ? encodedLine : withoutExisting + "\n" + encodedLine
    }

    /// Strips any `cal://` line from `notesText`, leaving everything else (including other
    /// control lines) untouched — used both by `appending` and by an explicit unlink.
    public static func removing(from notesText: String) -> String {
        notesText.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(scheme) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: "|", with: "%7C")
         .replacingOccurrences(of: "\n", with: "%0A")
    }
    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "%0A", with: "\n").replacingOccurrences(of: "%7C", with: "|")
         .replacingOccurrences(of: "%25", with: "%")
    }
}

/// Pure name-fold match used both by the inspector's manual "link" list and by auto-link:
/// folded title equality is the same comparison `CoachSettings.learn(eventTitle:)` uses for
/// its own event-title matching, so a block that auto-links a project also reads as an
/// obvious match here.
public enum TaskCalendarAutoLink {
    /// True when `eventTitle` should auto-link to a task/project named `subjectName` without
    /// asking — exact fold match only (never a substring/fuzzy match: a false auto-link is
    /// worse than asking once).
    public static func matches(eventTitle: String, subjectName: String) -> Bool {
        !subjectName.isEmpty && KTextFold.fold(eventTitle) == KTextFold.fold(subjectName)
    }
}
