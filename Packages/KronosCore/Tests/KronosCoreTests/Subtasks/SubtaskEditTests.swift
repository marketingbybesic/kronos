import Testing
import Foundation
@testable import KronosCore

/// Editing an existing step's due day and priority: one undo step each,
/// no-op pushes nothing, undo/redo restore exactly, and a general task edit's
/// undo snapshot keeps the steps' due/priority.
@MainActor
@Suite("SubtaskEditTests")
struct SubtaskEditTests {

    private func make(due: String? = nil, priority: KPriority = .none) throws -> (TaskStore, UUID, UUID) {
        let store = try TaskStore(inMemory: true)
        let t = store.createNoUndo(title: "Parent")
        let s = try #require(store.addSubtaskNoUndo(t.id, title: "step", dueDay: due.map(SubtaskFixture.day), priority: priority))
        return (store, t.id, s.id)
    }

    @Test func setDueIsOneStepAndUndoRedoRestore() throws {
        let (store, _, sid) = try make(due: "2026-10-12")
        let depth = store.undoDepth
        store.setSubtaskDueDay(sid, SubtaskFixture.day("2026-10-20"))
        #expect(store.undoDepth == depth + 1)
        #expect(SubtaskFixture.iso(store.subtask(sid)?.dueDay) == "2026-10-20")
        store.undo()
        #expect(SubtaskFixture.iso(store.subtask(sid)?.dueDay) == "2026-10-12")
        #expect(store.undoDepth == depth)
        store.redo()
        #expect(SubtaskFixture.iso(store.subtask(sid)?.dueDay) == "2026-10-20")
        store.undo()
        #expect(SubtaskFixture.iso(store.subtask(sid)?.dueDay) == "2026-10-12")
    }

    @Test func clearingDueIsUndoable() throws {
        let (store, _, sid) = try make(due: "2026-10-12")
        store.setSubtaskDueDay(sid, nil)
        #expect(store.subtask(sid)?.dueDay == nil)
        store.undo()
        #expect(SubtaskFixture.iso(store.subtask(sid)?.dueDay) == "2026-10-12")
    }

    @Test func setPriorityIsOneStepAndUndoRedoRestore() throws {
        let (store, _, sid) = try make(priority: .low)
        let depth = store.undoDepth
        store.setSubtaskPriority(sid, .urgent)
        #expect(store.undoDepth == depth + 1)
        #expect(store.subtask(sid)?.priorityRaw == 4)
        store.undo()
        #expect(store.subtask(sid)?.priorityRaw == 1)
        store.redo()
        #expect(store.subtask(sid)?.priorityRaw == 4)
        store.undo()
        #expect(store.subtask(sid)?.priorityRaw == 1)
        #expect(store.undoDepth == depth)
    }

    @Test func sameValuePushesNothing() throws {
        let (store, _, sid) = try make(due: "2026-10-12", priority: .high)
        let depth = store.undoDepth
        let before = SubtaskFixture.dump(store)
        store.setSubtaskDueDay(sid, SubtaskFixture.day("2026-10-12"))
        store.setSubtaskPriority(sid, .high)
        #expect(store.undoDepth == depth)
        #expect(SubtaskFixture.dump(store) == before)
        // clearing an already-nil due is also a no-op
        let (s2, _, id2) = try make()
        let d2 = s2.undoDepth
        s2.setSubtaskDueDay(id2, nil)
        s2.setSubtaskPriority(id2, .none)
        #expect(s2.undoDepth == d2)
    }

    @Test func noOpPreservesRedoStack() throws {
        let (store, _, sid) = try make()
        store.setSubtaskPriority(sid, .medium)
        store.undo()
        #expect(store.canRedo)
        store.setSubtaskPriority(sid, .none)   // already none: must not clear redo
        #expect(store.canRedo)
    }

    @Test func missingIdIsNoOp() throws {
        let (store, _, _) = try make()
        let depth = store.undoDepth
        let before = SubtaskFixture.dump(store)
        store.setSubtaskDueDay(UUID(), SubtaskFixture.day("2026-10-20"))
        store.setSubtaskPriority(UUID(), .urgent)
        #expect(store.undoDepth == depth)
        #expect(SubtaskFixture.dump(store) == before)
    }

    @Test func editsDoNotTouchOtherFields() throws {
        let (store, _, sid) = try make(due: "2026-10-12", priority: .low)
        store.toggleSubtask(sid)
        store.renameSubtask(sid, title: "renamed")
        store.setSubtaskPriority(sid, .high)
        let s = try #require(store.subtask(sid))
        #expect(s.title == "renamed")
        #expect(s.isDone)
        #expect(SubtaskFixture.iso(s.dueDay) == "2026-10-12")
        #expect(s.priorityRaw == 3)
    }

    /// CHANGED EXPECTATION (subtasks became tasks): a step is its own row with its own undo
    /// snapshot, so a parent edit no longer carries the steps' fields. What must hold instead:
    /// undoing a parent edit leaves a step's own edit alone, and each undoes separately.
    @Test func parentEditUndoLeavesTheStepsOwnEditAlone() throws {
        let (store, tid, sid) = try make(due: "2026-10-12", priority: .low)
        store.setSubtaskDueDay(sid, SubtaskFixture.day("2026-11-01"))
        store.setSubtaskPriority(sid, .urgent)
        store.update(tid) { $0.title = "Parent edited" }
        store.undo()
        #expect(store.task(tid)?.title == "Parent")
        #expect(SubtaskFixture.iso(store.subtask(sid)?.dueDay) == "2026-11-01")
        #expect(store.subtask(sid)?.priorityRaw == 4)
        store.undo()
        #expect(store.subtask(sid)?.priorityRaw == 1)
        store.undo()
        #expect(SubtaskFixture.iso(store.subtask(sid)?.dueDay) == "2026-10-12")
    }

    @Test func clearedStepDueUndoesBack() throws {
        let (store, _, sid) = try make(due: "2026-10-12")
        store.setSubtaskDueDay(sid, nil)
        #expect(store.subtask(sid)?.dueDay == nil)
        store.undo()
        #expect(SubtaskFixture.iso(store.subtask(sid)?.dueDay) == "2026-10-12")
    }
}
