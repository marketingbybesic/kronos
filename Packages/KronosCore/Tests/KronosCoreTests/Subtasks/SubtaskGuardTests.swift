import Testing
import Foundation
@testable import KronosCore

/// Nesting is refused, with a typed error and no side effect, for the row itself as target,
/// a subtask as target (one level) and missing rows.
///
/// CHANGED EXPECTATION (subtasks became tasks): a recurring task and a task with a calendar
/// event used to be refused because a KSubtask had no repeat rule or event to carry them. A
/// subtask is now a full task that keeps both, so those two cases now NEST and keep the field.
@MainActor
@Suite("SubtaskGuardTests")
struct SubtaskGuardTests {

    private func expectRefused(_ store: TaskStore, child: UUID, parent: UUID,
                               error expected: TaskNestError) {
        let before = SubtaskFixture.dump(store)
        let depth = store.undoDepth
        var thrown: TaskNestError?
        do { try store.makeTaskSubtaskOf(child, parentID: parent) }
        catch let e as TaskNestError { thrown = e }
        catch { Issue.record("unexpected error type \(error)") }
        #expect(thrown == expected)
        #expect(SubtaskFixture.dump(store) == before, "a refused nest must change nothing")
        #expect(store.undoDepth == depth, "a refused nest must push no undo step")
    }

    @Test func recurringTaskNestsAndKeepsItsRule() throws {
        let store = try TaskStore(inMemory: true)
        let parent = store.createNoUndo(title: "Parent")
        let child = store.createNoUndo(title: "Water plants")
        child.recurrenceRule = "FREQ=WEEKLY"
        try store.makeTaskSubtaskOf(child.id, parentID: parent.id)
        let nested = try #require(store.task(child.id))
        #expect(nested.parentID == parent.id)
        #expect(nested.recurrenceRule == "FREQ=WEEKLY")
    }

    @Test func taskWithCalendarEventNestsAndKeepsTheEvent() throws {
        let store = try TaskStore(inMemory: true)
        let parent = store.createNoUndo(title: "Parent")
        let child = store.createNoUndo(title: "Dentist")
        child.calendarEventID = "event-1"
        try store.makeTaskSubtaskOf(child.id, parentID: parent.id)
        let nested = try #require(store.task(child.id))
        #expect(nested.parentID == parent.id)
        #expect(nested.calendarEventID == "event-1")
    }

    @Test func aSubtaskIsNeverATarget() throws {
        let store = try TaskStore(inMemory: true)
        let parent = store.createNoUndo(title: "Parent")
        let step = try #require(store.addSubtaskNoUndo(parent.id, title: "Step"))
        let other = store.createNoUndo(title: "Other")
        expectRefused(store, child: other.id, parent: step.id, error: .parentIsSubtask)
        // and a parent cannot be nested under its own child
        expectRefused(store, child: parent.id, parent: step.id, error: .parentIsSubtask)
    }

    @Test func taskCannotBecomeItsOwnSubtask() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.createNoUndo(title: "Solo")
        expectRefused(store, child: t.id, parent: t.id, error: .sameTask)
    }

    @Test func missingRowsAreRefused() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.createNoUndo(title: "Real")
        expectRefused(store, child: UUID(), parent: t.id, error: .taskNotFound)
        expectRefused(store, child: t.id, parent: UUID(), error: .parentNotFound)
    }

    @Test func plainTaskUnderARecurringParentIsAllowed() throws {
        // The guard is about the task that moves (a step has no repeat rule or event of its own),
        // not about the target: adding a step to a recurring task was always allowed.
        let store = try TaskStore(inMemory: true)
        let parent = store.createNoUndo(title: "Weekly review")
        parent.recurrenceRule = "FREQ=WEEKLY"
        let child = store.createNoUndo(title: "Plain")
        try store.makeTaskSubtaskOf(child.id, parentID: parent.id)
        #expect(store.task(parent.id)?.orderedSubtasks.map(\.title) == ["Plain"])
    }
}
