import Testing
import Foundation
@testable import KronosCore

/// Steps carry an optional due day and a priority. In schema V2 a step is a child task; the
/// frozen V1 step row's defaults are checked by `LegacyStepConversionTests`.
@MainActor
@Suite("SubtaskFieldTests")
struct SubtaskFieldTests {

    @Test func addedStepHasNoDueAndNoPriority() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.createNoUndo(title: "Parent")
        let s = try #require(store.addSubtaskNoUndo(t.id, title: "Plain"))
        #expect(s.dueDay == nil)
        #expect(s.priorityRaw == 0)
    }

    @Test func valuesStickAndPriorityMapsToTheEnum() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.createNoUndo(title: "Parent")
        let s = try #require(store.addSubtaskNoUndo(t.id, title: "Step"))
        s.dueDay = Day.parseISO("2026-10-15")
        s.priority = .urgent
        #expect(SubtaskFixture.iso(s.dueDay) == "2026-10-15")
        #expect(s.priorityRaw == 4)
    }

    @Test func fieldsSurviveASaveAndRefetch() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.createNoUndo(title: "Parent")
        let s = try #require(store.addSubtaskNoUndo(t.id, title: "Dated", dueDay: SubtaskFixture.day("2026-11-02"), priority: .high))
        let id = s.id
        let again = try #require(store.subtask(id))
        #expect(SubtaskFixture.iso(again.dueDay) == "2026-11-02")
        #expect(again.priorityRaw == 3)
    }
}
