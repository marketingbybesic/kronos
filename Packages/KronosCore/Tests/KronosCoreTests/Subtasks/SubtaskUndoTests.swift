import Testing
import Foundation
@testable import KronosCore

/// Every move/convert is ONE undo step, undo restores the exact prior rows
/// (ids, sortIndex, every field), and a no-op pushes nothing.
@MainActor
@Suite("SubtaskUndoTests")
struct SubtaskUndoTests {

    /// Parent with one step, plus a rich child task: ordo slot, project, label,
    /// due, priority, notes, two steps, and a waiter pointing at it.
    private struct World {
        let store: TaskStore
        let parentID: UUID
        let childID: UUID
        let waiterID: UUID
        let childSubIDs: [UUID]
    }

    private func makeWorld() throws -> World {
        let store = try TaskStore(inMemory: true)
        let project = store.createProject(name: "Home")
        let parent = store.createNoUndo(title: "Parent", project: project)
        store.addSubtaskNoUndo(parent.id, title: "p1")
        let child = store.createNoUndo(title: "Child", notes: "body\nlink://web|Example|https://example.com",
                                       project: project, priority: .high,
                                       dueDay: SubtaskFixture.day("2026-10-14"))
        store.sendToOrdo(child.id)
        let a1 = try #require(store.addSubtaskNoUndo(child.id, title: "a1", dueDay: SubtaskFixture.day("2026-10-12"), priority: .low))
        let a2 = try #require(store.addSubtaskNoUndo(child.id, title: "a2"))
        let waiter = store.createNoUndo(title: "Waiter")
        waiter.waitsOnIDs = child.id.uuidString
        return World(store: store, parentID: parent.id, childID: child.id,
                     waiterID: waiter.id, childSubIDs: [a1.id, a2.id])
    }

    @Test func nestIsOneUndoStepAndUndoRestoresEverything() throws {
        let w = try makeWorld()
        let s = w.store
        let before = SubtaskFixture.dump(s)
        let depth = s.undoDepth

        try s.makeTaskSubtaskOf(w.childID, parentID: w.parentID)
        #expect(s.undoDepth == depth + 1, "exactly one undo step")
        let after = SubtaskFixture.dump(s)
        #expect(after != before)

        s.undo()
        #expect(SubtaskFixture.dump(s) == before, "undo restores ids, sortIndex and every field")
        #expect(s.undoDepth == depth)
        #expect(s.task(w.childID)?.orderedSubtasks.map(\.id) == w.childSubIDs)
        #expect(s.task(w.waiterID)?.waitsOn == [w.childID])
        #expect(s.task(w.childID)?.isInOrdo == true)

        // redo reproduces the post-nest state, and undo works again after redo
        s.redo()
        #expect(SubtaskFixture.dump(s) == after)
        s.undo()
        #expect(SubtaskFixture.dump(s) == before)
    }

    @Test func promoteIsOneUndoStepAndUndoRestoresTheSubtask() throws {
        let w = try makeWorld()
        let s = w.store
        let stepID = w.childSubIDs[0]
        let before = SubtaskFixture.dump(s)
        let depth = s.undoDepth

        let promoted = try #require(s.promoteSubtaskToTask(stepID))
        #expect(s.undoDepth == depth + 1)
        let after = SubtaskFixture.dump(s)
        #expect(promoted.id == stepID, "promotion keeps the row and its id")
        #expect(s.task(promoted.id)?.parentID == nil)

        s.undo()
        #expect(SubtaskFixture.dump(s) == before)
        #expect(s.task(promoted.id)?.parentID == w.childID)

        s.redo()
        #expect(SubtaskFixture.dump(s) == after)
        s.undo()
        #expect(SubtaskFixture.dump(s) == before)
    }

    @Test func reparentIsOneUndoStepAndUndoRestoresOwnerAndSortIndex() throws {
        let w = try makeWorld()
        let s = w.store
        let stepID = w.childSubIDs[1]
        let before = SubtaskFixture.dump(s)
        let depth = s.undoDepth

        s.reparentSubtask(stepID, under: w.parentID)
        #expect(s.undoDepth == depth + 1)
        #expect(s.subtask(stepID)?.parentID == w.parentID)
        let after = SubtaskFixture.dump(s)

        s.undo()
        #expect(SubtaskFixture.dump(s) == before)

        s.redo()
        #expect(SubtaskFixture.dump(s) == after)
    }

    @Test func noOpsPushNoUndoStep() throws {
        let w = try makeWorld()
        let s = w.store
        let before = SubtaskFixture.dump(s)
        let depth = s.undoDepth

        // reparent onto the current person, onto nothing, and a missing subtask
        s.reparentSubtask(w.childSubIDs[0], under: w.childID)
        s.reparentSubtask(w.childSubIDs[0], under: UUID())
        s.reparentSubtask(UUID(), under: w.parentID)
        // nest onto itself, and a missing task
        #expect(throws: TaskNestError.self) { try s.makeTaskSubtaskOf(w.childID, parentID: w.childID) }
        #expect(throws: TaskNestError.self) { try s.makeTaskSubtaskOf(UUID(), parentID: w.parentID) }
        // promote of a missing subtask
        #expect(s.promoteSubtaskToTask(UUID()) == nil)

        #expect(s.undoDepth == depth)
        #expect(SubtaskFixture.dump(s) == before)
    }

    @Test func aNoOpKeepsAPendingRedo() throws {
        let w = try makeWorld()
        let s = w.store
        try s.makeTaskSubtaskOf(w.childID, parentID: w.parentID)
        s.undo()
        #expect(s.canRedo)
        // a no-op must not destroy a pending redo
        s.reparentSubtask(UUID(), under: w.parentID)
        #expect(s.canRedo)
    }
}
