// rev 4 — the grouped-undo primitive, and the recurrence hook that is its
// first production consumer.
//
// Before rev 4, `RecurrenceSpawner` reached into `undoStack`/`redoStack` to
// pop the completion's step, merge, and push it back. That worked and was
// tested, but every future "one action, several writes" case would have had
// to copy the trick. `groupedUndo` states the idea once.

import Testing
import Foundation
@testable import KronosCore

@MainActor
struct GroupedUndoTests {

    private func makeStore() throws -> TaskStore { try TaskStore(inMemory: true) }

    @Test func groupedUndoRevertsAllMutationsInOneStep() throws {
        let store = try makeStore()
        let a = store.create(title: "A", notes: "", project: nil,
                             status: .todo, priority: .none, dueDay: nil)
        let b = store.create(title: "B", notes: "", project: nil,
                             status: .todo, priority: .none, dueDay: nil)
        let c = store.create(title: "C", notes: "", project: nil,
                             status: .todo, priority: .none, dueDay: nil)
        let depth = store.undoDepth

        store.groupedUndo("Bulk edit") {
            store.setPriority(a.id, .urgent)
            store.setPriority(b.id, .urgent)
            store.setPriority(c.id, .urgent)
            store.update(a.id) { $0.notes = "touched" }
        }

        // Four writes, ONE step.
        #expect(store.undoDepth == depth + 1)
        #expect(store.task(a.id)?.priority == KPriority.urgent)
        #expect(store.task(b.id)?.priority == KPriority.urgent)
        #expect(store.task(c.id)?.priority == KPriority.urgent)
        #expect(store.task(a.id)?.notes == "touched")

        store.undo()

        // One Cmd-Z reverses everything the group did — including the note,
        // which was written last and must therefore be reverted first.
        #expect(store.undoDepth == depth)
        #expect(store.task(a.id)?.priority == KPriority.none)
        #expect(store.task(b.id)?.priority == KPriority.none)
        #expect(store.task(c.id)?.priority == KPriority.none)
        #expect(store.task(a.id)?.notes == "")

        store.redo()
        #expect(store.task(a.id)?.priority == KPriority.urgent)
        #expect(store.task(b.id)?.priority == KPriority.urgent)
        #expect(store.task(c.id)?.priority == KPriority.urgent)
        #expect(store.task(a.id)?.notes == "touched")
    }

    @Test func groupedUndoWithAnEmptyBodyPushesNothing() throws {
        let store = try makeStore()
        let t = store.create(title: "T", notes: "", project: nil,
                             status: .todo, priority: .none, dueDay: nil)
        let depth = store.undoDepth

        store.groupedUndo("Nothing") { }
        #expect(store.undoDepth == depth)

        // A body that only READS pushes nothing either — the group counts
        // steps, it does not manufacture one. (A body calling a mutation
        // that writes the same value it already held DOES push a step:
        // `mutateUndoable` snapshots unconditionally and has always done so,
        // which is a separate, pre-existing question about no-op writes.)
        store.groupedUndo("Read only") {
            _ = store.task(t.id)?.priority
        }
        #expect(store.undoDepth == depth)
    }

    @Test func groupedUndoDoesNotDestroyAPendingRedoWhenTheBodyIsEmpty() throws {
        let store = try makeStore()
        let t = store.create(title: "T", notes: "", project: nil,
                             status: .todo, priority: .none, dueDay: nil)
        store.setPriority(t.id, .high)
        store.undo()
        #expect(store.canRedo)

        store.groupedUndo("Nothing") { }

        // Nothing happened, so the redo the user is one keystroke away from
        // must survive.
        #expect(store.canRedo)
        store.redo()
        #expect(store.task(t.id)?.priority == KPriority.high)
    }

    @Test func nestedGroupedUndoCollapsesIntoTheOutermostStep() throws {
        let store = try makeStore()
        let a = store.create(title: "A", notes: "", project: nil,
                             status: .todo, priority: .none, dueDay: nil)
        let b = store.create(title: "B", notes: "", project: nil,
                             status: .todo, priority: .none, dueDay: nil)
        let depth = store.undoDepth

        store.groupedUndo("Outer") {
            store.setPriority(a.id, .high)
            store.groupedUndo("Inner") {
                store.setPriority(b.id, .urgent)
                store.setDread(b.id, true)
            }
        }

        #expect(store.undoDepth == depth + 1)
        store.undo()
        #expect(store.task(a.id)?.priority == KPriority.none)
        #expect(store.task(b.id)?.priority == KPriority.none)
        #expect(store.task(b.id)?.dread == false)
    }

    @Test func groupedUndoInsideANoUndoWriteStillLeavesTheStackUntouched() throws {
        let store = try makeStore()
        let mine = store.create(title: "Moje", notes: "", project: nil,
                                status: .todo, priority: .none, dueDay: nil)
        let depth = store.undoDepth

        // completeNoUndo wraps complete(), which now opens a group. The
        // group pushes exactly one step, which the NoUndo truncation then
        // removes — if the arithmetic were off, an MCP batch would start
        // burying the user's own last action again.
        let theirs = store.createNoUndo(title: "MCP", notes: "", project: nil,
                                        status: .todo, priority: .none, dueDay: nil)
        store.completeNoUndo(theirs.id)

        #expect(store.task(theirs.id)?.status == .done)
        #expect(store.undoDepth == depth)
        store.undo()
        #expect(store.task(mine.id) == nil)
    }

    // MARK: - The recurrence hook

    @Test func completingRecurringTaskThroughStoreSpawnsOneSuccessorAndOneUndoStep() throws {
        let store = try makeStore()
        let today = Day.today()
        let t = store.create(title: "Izdati račune", notes: "", project: nil,
                             status: .todo, priority: .high, dueDay: today)
        store.setRecurrence(t.id, RecurrenceRule.monthly(every: 1, day: 1,
                                                         anchor: .fromDueDay).wireFormat)
        let countBefore = store.allTasks().count
        let depthBefore = store.undoDepth

        // Through TaskStoring.complete — NOT by calling the spawner directly.
        // The spawner has always worked; what the UI leaves needed was for an
        // ordinary completion to trigger it.
        let storing: any TaskStoring = store
        storing.complete(t.id)

        #expect(store.allTasks().count == countBefore + 1)
        // Exactly ONE step: the completion and the spawn are one user action.
        #expect(store.undoDepth == depthBefore + 1)

        let spawned = try #require(store.allTasks().first { $0.id != t.id })
        #expect(spawned.title == "Izdati račune")
        #expect(spawned.priority == KPriority.high)
        #expect(spawned.seriesID != nil)
        #expect(spawned.seriesID == store.task(t.id)?.seriesID)

        store.undo()
        #expect(store.undoDepth == depthBefore)
        #expect(store.allTasks().count == countBefore)
        #expect(store.task(t.id)?.status == .todo)
        #expect(store.task(t.id)?.completedAt == nil)

        store.redo()
        #expect(store.task(t.id)?.status == .done)
        #expect(store.allTasks().count == countBefore + 1)
    }

    @Test func completingAnAlreadyDoneRecurringTaskSpawnsNothing() throws {
        let store = try makeStore()
        let t = store.create(title: "Tjedni izvještaj", notes: "", project: nil,
                             status: .todo, priority: .none, dueDay: Day.today())
        store.setRecurrence(t.id, RecurrenceRule.weekly(every: 1, weekdays: [1],
                                                        anchor: .fromDueDay).wireFormat)
        store.complete(t.id)
        let afterFirst = store.allTasks().count

        // A double-click, or an MCP retry, must not produce a second sibling.
        store.complete(t.id)
        #expect(store.allTasks().count == afterFirst)
    }

    @Test func mcpCompletionAlsoSpawnsTheSuccessor() throws {
        let store = try makeStore()
        let t = store.create(title: "Mjesečni obračun", notes: "", project: nil,
                             status: .todo, priority: .none, dueDay: Day.today())
        store.setRecurrence(t.id, RecurrenceRule.daily(every: 1, anchor: .fromDueDay).wireFormat)
        let countBefore = store.allTasks().count
        let depthBefore = store.undoDepth

        store.completeNoUndo(t.id)

        // A completion arriving over MCP must recur exactly like one made in
        // the UI — and still push no undo step.
        #expect(store.allTasks().count == countBefore + 1)
        #expect(store.undoDepth == depthBefore)
    }

    @Test func completingANonRecurringTaskStillPushesExactlyOneStep() throws {
        let store = try makeStore()
        let t = store.create(title: "Jednokratno", notes: "", project: nil,
                             status: .todo, priority: .none, dueDay: nil)
        let depth = store.undoDepth

        store.complete(t.id)
        // Wrapping complete() in a group must not change the undo arithmetic
        // for the overwhelmingly common non-recurring case.
        #expect(store.undoDepth == depth + 1)
        #expect(store.allTasks().count == 1)

        store.undo()
        #expect(store.task(t.id)?.status == .todo)
    }
}
