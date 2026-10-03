import Testing
import Foundation
@testable import KronosCore

/// Cmd-] (nest under the task above) and Cmd-[ (promote right behind the parent).
@MainActor
@Suite("KeyboardNestingTests")
struct KeyboardNestingTests {

    // MARK: taskAbove (pure)

    @Test func taskAboveTable() {
        let ids = (0..<4).map { _ in UUID() }
        #expect(KeyboardNesting.taskAbove(ids[0], in: ids) == nil, "first row has nothing above")
        #expect(KeyboardNesting.taskAbove(ids[1], in: ids) == ids[0])
        #expect(KeyboardNesting.taskAbove(ids[3], in: ids) == ids[2])
        #expect(KeyboardNesting.taskAbove(UUID(), in: ids) == nil, "not in the list")
        #expect(KeyboardNesting.taskAbove(ids[0], in: []) == nil)
        // The list order given by the caller decides, not creation order.
        #expect(KeyboardNesting.taskAbove(ids[0], in: [ids[2], ids[0]]) == ids[2])
    }

    // MARK: nest

    @Test func nestsUnderTheRowAboveInTheGivenOrderAndIsOneUndoStep() throws {
        let store = try TaskStore(inMemory: true)
        let a = store.createNoUndo(title: "A")
        let b = store.createNoUndo(title: "B", dueDay: SubtaskFixture.day("2026-10-12"))
        let c = store.createNoUndo(title: "C")
        // Display order differs from creation order: C, A, B. Above B is A.
        let before = SubtaskFixture.dump(store)
        let depth = store.undoDepth

        let outcome = store.nestUnderTaskAbove(b.id, rows: [c.id, a.id, b.id])

        #expect(outcome == .nested(parentID: a.id))
        #expect(store.task(b.id)?.parentID == a.id, "same row, now a subtask")
        #expect(store.task(a.id)?.orderedSubtasks.map(\.title) == ["B"])
        #expect(SubtaskFixture.iso(store.task(a.id)?.orderedSubtasks.first?.dueDay) == "2026-10-12")
        #expect(store.undoDepth == depth + 1)

        store.undo()
        #expect(SubtaskFixture.dump(store) == before)
    }

    @Test func firstRowRefusesWithoutChangingAnything() throws {
        let store = try TaskStore(inMemory: true)
        let a = store.createNoUndo(title: "A")
        let b = store.createNoUndo(title: "B")
        let before = SubtaskFixture.dump(store)
        let depth = store.undoDepth
        #expect(store.nestUnderTaskAbove(a.id, rows: [a.id, b.id]) == .noTaskAbove)
        #expect(SubtaskFixture.dump(store) == before)
        #expect(store.undoDepth == depth)
    }

    /// CHANGED EXPECTATION (subtasks became tasks): recurring and calendar tasks used to be
    /// refused; they now nest and keep their rule/event. The typed refusal that remains is a
    /// subtask directly above (one level only): now handled as a sibling (next test).
    @Test func recurringAndCalendarTasksNest() throws {
        let store = try TaskStore(inMemory: true)
        let a = store.createNoUndo(title: "A")
        let rec = store.createNoUndo(title: "Rec")
        rec.recurrenceRule = "FREQ=WEEKLY"
        let cal = store.createNoUndo(title: "Cal")
        cal.calendarEventID = "event-1"
        #expect(store.nestUnderTaskAbove(rec.id, rows: [a.id, rec.id, cal.id]) == .nested(parentID: a.id))
        #expect(store.task(rec.id)?.recurrenceRule == "FREQ=WEEKLY")
        #expect(store.nestUnderTaskAbove(cal.id, rows: [a.id, cal.id]) == .nested(parentID: a.id))
        #expect(store.task(cal.id)?.calendarEventID == "event-1")

    }

    /// Per Amendment 2: the row above is itself a child -> the task becomes its SIBLING (same
    /// parent), one undo step; when the task is that child's own parent it is refused (self).
    @Test func aSubtaskAboveMakesTheTaskItsSibling() throws {
        let store = try TaskStore(inMemory: true)
        let a = store.createNoUndo(title: "A")
        let kid = store.createNoUndo(title: "Kid")
        try store.setParent(kid.id, to: a.id)
        let x = store.createNoUndo(title: "X")
        let before = SubtaskFixture.dump(store)
        let depth = store.undoDepth

        #expect(store.nestUnderTaskAbove(x.id, rows: [kid.id, x.id]) == .nested(parentID: a.id))
        #expect(store.task(a.id)?.orderedSubtasks.map(\.title) == ["Kid", "X"])
        #expect(store.undoDepth == depth + 1)
        store.undo()
        #expect(SubtaskFixture.dump(store) == before)

        // The task above is a child of the task itself: nesting under itself is refused, nothing pushed.
        #expect(store.nestUnderTaskAbove(a.id, rows: [kid.id, a.id]) == .refused(.sameTask))
        #expect(SubtaskFixture.dump(store) == before)
        #expect(store.undoDepth == depth)
    }

    @Test func nestingATaskWithStepsFlattensThemUnderTheParent() throws {
        let store = try TaskStore(inMemory: true)
        let a = store.createNoUndo(title: "A")
        let b = store.createNoUndo(title: "B")
        _ = store.addSubtaskNoUndo(b.id, title: "b1")
        _ = store.addSubtaskNoUndo(b.id, title: "b2")
        #expect(store.nestUnderTaskAbove(b.id, rows: [a.id, b.id]) == .nested(parentID: a.id))
        #expect(store.task(a.id)?.orderedSubtasks.map(\.title) == ["B", "b1", "b2"])
    }

    // MARK: promote

    @Test func promoteLandsDirectlyAfterTheParentInManualOrder() throws {
        let store = try TaskStore(inMemory: true)
        let first = store.createNoUndo(title: "First")
        let parent = store.createNoUndo(title: "Parent")
        let last = store.createNoUndo(title: "Last")
        let s = try #require(store.addSubtaskNoUndo(parent.id, title: "Step", dueDay: SubtaskFixture.day("2026-10-14"), priority: .high))
        let before = SubtaskFixture.dump(store)
        let depth = store.undoDepth

        let t = try #require(store.promoteSubtaskAfterParent(s.id))

        let manual = KTaskSorter.sorted(store.allTasks(), by: [.asc(.manual)]).map(\.title)
        #expect(manual == ["First", "Parent", "Step", "Last"])
        #expect(t.title == "Step")
        #expect(SubtaskFixture.iso(t.dueDay) == "2026-10-14")
        #expect(t.priorityRaw == 3)
        #expect(store.undoDepth == depth + 1)
        _ = (first, last)

        store.undo()
        #expect(SubtaskFixture.dump(store) == before)
    }

    @Test func promoteAfterTheLastTaskGoesToTheEnd() throws {
        let store = try TaskStore(inMemory: true)
        let parent = store.createNoUndo(title: "Parent")
        let s = try #require(store.addSubtaskNoUndo(parent.id, title: "Step"))
        _ = try #require(store.promoteSubtaskAfterParent(s.id))
        #expect(KTaskSorter.sorted(store.allTasks(), by: [.asc(.manual)]).map(\.title) == ["Parent", "Step"])
    }

    @Test func promoteRedoKeepsThePosition() throws {
        let store = try TaskStore(inMemory: true)
        let parent = store.createNoUndo(title: "Parent")
        _ = store.createNoUndo(title: "Last")
        let s = try #require(store.addSubtaskNoUndo(parent.id, title: "Step"))
        _ = try #require(store.promoteSubtaskAfterParent(s.id))
        store.undo()
        store.redo()
        #expect(KTaskSorter.sorted(store.allTasks(), by: [.asc(.manual)]).map(\.title) == ["Parent", "Step", "Last"])
    }

    @Test func promoteOfAMissingSubtaskDoesNothing() throws {
        let store = try TaskStore(inMemory: true)
        _ = store.createNoUndo(title: "A")
        let depth = store.undoDepth
        #expect(store.promoteSubtaskAfterParent(UUID()) == nil)
        #expect(store.undoDepth == depth)
    }
}
