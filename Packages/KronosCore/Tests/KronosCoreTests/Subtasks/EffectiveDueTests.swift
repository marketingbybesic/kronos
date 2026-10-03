import Testing
import Foundation
@testable import KronosCore

/// effectiveDue = min(own due, due of every UNDONE subtask that has one).
@MainActor
@Suite("EffectiveDueTests")
struct EffectiveDueTests {

    private struct Row {
        let name: String
        let own: String?
        let steps: [(due: String?, done: Bool)]
        let expected: String?
    }

    private let table: [Row] = [
        Row(name: "own only", own: "2026-10-20", steps: [], expected: "2026-10-20"),
        Row(name: "nothing at all", own: nil, steps: [], expected: nil),
        Row(name: "undone step earlier than own", own: "2026-10-20", steps: [("2026-10-10", false)], expected: "2026-10-10"),
        Row(name: "undone step later than own", own: "2026-10-20", steps: [("2026-10-30", false)], expected: "2026-10-20"),
        Row(name: "step due, task undated", own: nil, steps: [("2026-10-12", false)], expected: "2026-10-12"),
        Row(name: "done step ignored", own: "2026-10-20", steps: [("2026-10-10", true)], expected: "2026-10-20"),
        Row(name: "done step ignored, task undated", own: nil, steps: [("2026-10-10", true)], expected: nil),
        Row(name: "earliest of several undone", own: "2026-10-20", steps: [("2026-10-18", false), ("2026-10-11", false), ("2026-10-15", false)], expected: "2026-10-11"),
        Row(name: "undone later wins over done earlier", own: nil, steps: [("2026-10-01", true), ("2026-10-09", false)], expected: "2026-10-09"),
        Row(name: "steps without a due day change nothing", own: "2026-10-20", steps: [(nil, false), (nil, true)], expected: "2026-10-20"),
        Row(name: "same day", own: "2026-10-20", steps: [("2026-10-20", false)], expected: "2026-10-20"),
    ]

    @Test func tableMatchesHandWrittenExpectations() throws {
        for row in table {
            let store = try TaskStore(inMemory: true)
            let t = store.createNoUndo(title: row.name)
            t.dueDay = row.own.map(SubtaskFixture.day)
            for step in row.steps {
                let s = try #require(store.addSubtaskNoUndo(t.id, title: "s"))
                s.dueDay = step.due.map(SubtaskFixture.day)
                s.isDone = step.done
            }
            let got = t.effectiveDue.map(Day.iso)
            #expect(got == row.expected, "\(row.name): got \(String(describing: got))")
        }
    }

    @Test func completingTheEarlySubtaskMovesEffectiveDueBackToTheOwnDay() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.createNoUndo(title: "Trip", dueDay: SubtaskFixture.day("2026-10-20"))
        let s = try #require(store.addSubtaskNoUndo(t.id, title: "Book flight", dueDay: SubtaskFixture.day("2026-10-10"), priority: .none))
        #expect(t.effectiveDue.map(Day.iso) == "2026-10-10")
        store.toggleSubtaskNoUndo(s.id, isDone: true)
        #expect(t.effectiveDue.map(Day.iso) == "2026-10-20")
    }
}
