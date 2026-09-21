// Covers the link/unlink round trip on `TaskCalendarLink` directly. A prior "unlink does
// nothing" bug turned out to live in the app target (InspectorScreen.swift never read
// `model.version`, so SwiftUI never re-ran `body` after the mutation) rather than in this
// type's own `removing(from:)`, which was already correct — kept here as real coverage of the
// round trip regardless of where a future regression might live.
import Testing
import Foundation
@testable import KronosCore

struct ContextLinkCalendarTests {
    @Test func taskCalendarLinkRoundTrips() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(1800)
        let link = TaskCalendarLink(eventID: "evt-1", title: "Standup", start: start, end: end)
        let withLink = link.appending(to: "Some task notes")
        let found = TaskCalendarLink.find(in: withLink)
        #expect(found?.eventID == "evt-1")
        #expect(found?.title == "Standup")
        #expect(found?.start == start)
        #expect(found?.end == end)
        #expect(withLink.contains("Some task notes"))
    }

    /// Link, then unlink, and the line must really be gone — `removing(from:)` is what
    /// `InspectorCalendarBlockRow.unlink()` calls.
    @Test func unlinkReallyRemovesTheLine() {
        let link = TaskCalendarLink(eventID: "evt-2", title: "Focus block",
                                    start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 900))
        let withLink = link.appending(to: "Notes before")
        #expect(TaskCalendarLink.find(in: withLink) != nil)

        let unlinked = TaskCalendarLink.removing(from: withLink)
        #expect(TaskCalendarLink.find(in: unlinked) == nil)
        #expect(unlinked == "Notes before")
        #expect(!unlinked.components(separatedBy: "\n").contains { $0.hasPrefix("cal://") })
    }

    @Test func removingFromTextWithNoLinkIsANoOp() {
        #expect(TaskCalendarLink.removing(from: "Plain notes") == "Plain notes")
    }

    /// Re-linking replaces rather than accumulates (own doc comment's contract), matching
    /// `NoteLink`/`ContextLink`'s "at most one at a time" rule.
    @Test func relinkingReplacesNotAccumulates() {
        let first = TaskCalendarLink(eventID: "evt-a", title: "A", start: .now, end: .now.addingTimeInterval(60))
        let second = TaskCalendarLink(eventID: "evt-b", title: "B", start: .now, end: .now.addingTimeInterval(60))
        let relinked = second.appending(to: first.appending(to: "Notes"))
        #expect(TaskCalendarLink.find(in: relinked)?.eventID == "evt-b")
        #expect(relinked.components(separatedBy: "\n").filter { $0.hasPrefix("cal://") }.count == 1)
    }

    /// A note link, a context link and a calendar link coexist independently (doc comment:
    /// "a task can carry a note link, a context link AND a calendar link at once").
    @Test func coexistsWithNoteLinkAndContextLink() {
        var notes = "Some notes"
        notes = NoteLink.appending("note-1", to: notes)
        notes = ContextLink(kind: .web, reference: "https://example.com", displayName: "Example").appending(to: notes)
        notes = TaskCalendarLink(eventID: "evt-3", title: "Sync", start: .now, end: .now.addingTimeInterval(1800))
            .appending(to: notes)

        #expect(NoteLink.find(in: notes) == "note-1")
        #expect(ContextLink.find(in: notes)?.kind == .web)
        #expect(TaskCalendarLink.find(in: notes)?.eventID == "evt-3")

        // Unlinking the calendar block leaves the other two links untouched.
        let afterUnlink = TaskCalendarLink.removing(from: notes)
        #expect(TaskCalendarLink.find(in: afterUnlink) == nil)
        #expect(NoteLink.find(in: afterUnlink) == "note-1")
        #expect(ContextLink.find(in: afterUnlink)?.kind == .web)
    }

    @Test func autoLinkMatchesOnlyExactFoldedTitle() {
        #expect(TaskCalendarAutoLink.matches(eventTitle: "Standup", subjectName: "standup"))
        #expect(TaskCalendarAutoLink.matches(eventTitle: "Čišćenje", subjectName: "ciscenje"))
        #expect(!TaskCalendarAutoLink.matches(eventTitle: "Standup meeting", subjectName: "Standup"))
        #expect(!TaskCalendarAutoLink.matches(eventTitle: "Standup", subjectName: ""))
    }
}
