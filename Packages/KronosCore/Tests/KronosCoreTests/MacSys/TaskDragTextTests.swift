import Testing
import Foundation
@testable import KronosCore

/// What a task row puts on a drag as plain text: a dossier an agent in a terminal can read.
@Suite("TaskDragTextTests")
struct TaskDragTextTests {
    private let id = UUID(uuidString: "0F8C2A4E-7B1D-4C3A-9E55-1A2B3C4D5E6F")!
    private let link = "kronos://open?id=0F8C2A4E-7B1D-4C3A-9E55-1A2B3C4D5E6F"

    @Test func titleOnly() {
        let text = TaskDragText.render(.init(id: id, title: "Buy milk"))
        #expect(text == "# Buy milk\n\n" + link)
    }

    @Test func emptyTitleStillHasLinkLast() {
        let text = TaskDragText.render(.init(id: id, title: "   "))
        #expect(text == "# Untitled\n\n" + link)
    }

    @Test func fullDossier() throws {
        let due = try #require(Day.parseISO("2026-10-12"))
        let planned = try #require(Day.parseISO("2026-10-10"))
        let input = TaskDragText.Input(
            id: id, title: "Ship the report", status: .inProgress, priority: .high,
            dueDay: due, plannedDay: planned, projectName: "Q4", areaName: "Work",
            labels: ["alpha", "beta"], notes: "First line\nSecond line\n",
            steps: [.init(title: "Draft", isDone: true), .init(title: "Send", isDone: false)])
        let want = [
            "# Ship the report",
            "Status: in progress",
            "Priority: high",
            "Due: 2026-10-12",
            "Planned: 2026-10-10",
            "Project: Q4 (Work)",
            "Labels: alpha, beta",
            "",
            "Notes:",
            "First line",
            "Second line",
            "",
            "Steps:",
            "- [x] Draft",
            "- [ ] Send",
            "",
            link,
        ].joined(separator: "\n")
        #expect(TaskDragText.render(input) == want)
    }

    @Test func projectWithoutArea() {
        let text = TaskDragText.render(.init(id: id, title: "T", projectName: "Home"))
        #expect(text.contains("\nProject: Home\n"))
    }

    @Test func titleNewlinesCollapse() {
        let text = TaskDragText.render(.init(id: id, title: "a\nb  c"))
        #expect(text.hasPrefix("# a b c\n"))
    }

    @Test func hugeNotesAreClipped() {
        let notes = String(repeating: "x", count: 10_000)
        let text = TaskDragText.render(.init(id: id, title: "T", notes: notes))
        let want = "# T\n\nNotes:\n" + String(repeating: "x", count: 4000) + "\n[notes truncated]\n\n" + link
        #expect(text == want)
    }

    @Test func notesAtTheLimitAreKept() {
        let notes = String(repeating: "y", count: 4000)
        let text = TaskDragText.render(.init(id: id, title: "T", notes: notes))
        #expect(!text.contains("[notes truncated]"))
        #expect(text.contains(notes))
    }

    @Test func linkIsTheLastLine() {
        let text = TaskDragText.render(.init(id: id, title: "T", notes: "n",
                                             steps: [.init(title: "s", isDone: false)]))
        #expect(text.split(separator: "\n").last.map(String.init) == TaskLink.string(for: id))
    }

    @Test func blankStepsAreDropped() {
        let text = TaskDragText.render(.init(id: id, title: "T", steps: [.init(title: " ", isDone: false)]))
        #expect(!text.contains("Steps:"))
    }

    @Test func doneAndCanceledStatusesAreNamed() {
        #expect(TaskDragText.render(.init(id: id, title: "T", status: .done)).contains("Status: done"))
        #expect(TaskDragText.render(.init(id: id, title: "T", status: .canceled)).contains("Status: canceled"))
        #expect(!TaskDragText.render(.init(id: id, title: "T", status: .todo)).contains("Status:"))
    }
}
