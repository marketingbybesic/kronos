import Testing
import Foundation
@testable import KronosCore

/// Renaming a child task from the list: one undo step, an unchanged title pushes nothing,
/// undo/redo restore exactly, and only the title changes.
@MainActor
@Suite("SubtaskRenameTests")
struct SubtaskRenameTests {
    private func make() throws -> (TaskStore, UUID) {
        let store = try TaskStore(inMemory: true)
        let parent = store.createNoUndo(title: "Parent")
        let step = try #require(store.addSubtaskNoUndo(parent.id, title: "old name", dueDay: nil, priority: .high))
        return (store, step.id)
    }

    @Test func renameIsOneUndoStepAndUndoRedoRestore() throws {
        let (store, sid) = try make()
        let depth = store.undoDepth
        store.renameSubtask(sid, title: "new name")
        #expect(store.undoDepth == depth + 1)
        #expect(store.task(sid)?.title == "new name")
        store.undo()
        #expect(store.task(sid)?.title == "old name")
        #expect(store.undoDepth == depth)
        store.redo()
        #expect(store.task(sid)?.title == "new name")
    }

    @Test func sameTitleOrUnknownIdPushesNothing() throws {
        let (store, sid) = try make()
        let depth = store.undoDepth
        store.renameSubtask(sid, title: "old name")
        store.renameSubtask(UUID(), title: "ghost")
        #expect(store.undoDepth == depth)
        #expect(store.task(sid)?.title == "old name")
    }

    @Test func renameLeavesOtherFieldsAlone() throws {
        let (store, sid) = try make()
        store.renameSubtask(sid, title: "renamed")
        let s = try #require(store.task(sid))
        #expect(s.title == "renamed")
        #expect(s.priorityRaw == KPriority.high.rawValue)
        #expect(!s.isDone)
    }
}
