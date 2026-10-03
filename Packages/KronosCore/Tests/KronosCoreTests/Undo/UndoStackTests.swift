// Undo stack behaviour: a mutation that changes nothing pushes no step, the stack is capped at
// 200, and a step that touched a relationship resolves it by id (a rebuilt row is found).

import Testing
import Foundation
@testable import KronosCore

@MainActor
@Suite struct UndoStackTests {

    // MARK: No-op mutations

    @Test func samePriorityPushesNoStepAndKeepsRedoAndUpdatedAt() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.create(title: "A")
        store.setPriority(t.id, .high)
        let stamp = store.task(t.id)!.updatedAt
        let depth = store.undoDepth

        store.setPriority(t.id, .high)                       // the same value again
        #expect(store.undoDepth == depth, "same priority: no step")
        #expect(store.task(t.id)!.updatedAt == stamp, "same priority: updatedAt not bumped")

        store.undo()
        #expect(store.canRedo)
        store.setPriority(t.id, KPriority.none)              // equals the current value
        #expect(store.canRedo, "a no-op does not destroy the pending redo")
        store.update(t.id) { $0.title = $0.title }
        #expect(store.canRedo)
    }

    /// Positive control: a real change pushes exactly one step and bumps updatedAt.
    @Test func aRealChangePushesOneStepAndBumpsUpdatedAt() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.create(title: "A")
        let stamp = store.task(t.id)!.updatedAt
        let depth = store.undoDepth
        Thread.sleep(forTimeInterval: 0.01)
        store.setPriority(t.id, .urgent)
        #expect(store.undoDepth == depth + 1)
        #expect(store.task(t.id)!.updatedAt > stamp)
    }

    // MARK: Cap

    @Test func depthNeverExceedsTwoHundredAndTheOldestStepsFallOff() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.create(title: "A")
        // 250 steps: titles "v1" ... "v250".
        for i in 1...250 { store.update(t.id) { $0.title = "v\(i)" } }
        #expect(store.undoDepth == 200, "capped at 200")
        #expect(TaskStore.undoLimit == 200)

        var undone = 0
        while store.canUndo { store.undo(); undone += 1 }
        #expect(undone == 200)
        // The 200 newest steps were v51...v250: undoing all of them lands on v50.
        #expect(store.task(t.id)?.title == "v50")
    }

    @Test func clearingTheHistoryDropsUndoAndRedoButKeepsTheData() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.create(title: "A")
        for i in 1...210 { store.update(t.id) { $0.title = "v\(i)" } }
        store.undo()
        #expect(store.undoDepth == 199)
        #expect(store.canRedo)
        store.clearUndoHistory()
        #expect(store.undoDepth == 0)
        #expect(!store.canUndo && !store.canRedo)
        #expect(store.task(t.id)?.title == "v209")
        // After a clear the depth counts again from zero: one push = one step.
        store.update(t.id) { $0.title = "after" }
        #expect(store.undoDepth == 1)
        store.undo()
        #expect(store.task(t.id)?.title == "v209")
    }

    @Test func aMachineWriteAtTheCapDoesNotDropAUserStep() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.create(title: "A")
        for i in 1...200 { store.update(t.id) { $0.title = "v\(i)" } }
        #expect(store.undoDepth == 200)

        store.updateNoUndo(t.id) { $0.notes = "machine" }
        store.createNoUndo(title: "Machine task")
        #expect(store.undoDepth == 200, "machine writes neither add nor evict steps")

        store.undo()
        #expect(store.task(t.id)?.title == "v199", "the newest user step is still on top")
        #expect(store.task(t.id)?.notes == "machine")
    }

    @Test func aGroupLargerThanTheCapCollapsesIntoOneIntactStep() throws {
        let store = try TaskStore(inMemory: true)
        var ids: [UUID] = []
        for i in 0..<230 { ids.append(store.createNoUndo(title: "T\(i)").id) }
        let base = store.undoDepth
        store.groupedUndo("Bulk") {
            for id in ids { store.setPriority(id, .high) }   // 230 steps inside the group
        }
        #expect(store.undoDepth == base + 1, "one step for the whole group")
        #expect(ids.allSatisfy { store.task($0)?.priority == KPriority.high })
        store.undo()
        #expect(ids.allSatisfy { store.task($0)?.priority == KPriority.none }, "all 230 reverted by one Cmd-Z")
    }

    // MARK: Relationships by id

    /// Undoing a delete re-inserts a FRESH row with the old id (SwiftData cannot resurrect the dead
    /// instance). A snapshot taken before that must find the fresh row by id.
    @Test func snapshotResolvesALabelByIdAfterTheRowWasRebuilt() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.create(title: "A")
        let label = store.label(named: "Work")
        let labelID = label.id
        store.addLabel(label, to: t.id)
        let attached = TaskStore.TaskSnapshot(store.task(t.id)!)
        #expect(attached.labelIDs == [labelID])
        store.removeLabel(label, from: t.id)
        #expect(store.task(t.id)?.labels?.isEmpty == true)

        store.context.delete(label)                      // the rebuild: delete, save, insert a twin
        try store.context.save()
        let fresh = KLabel(name: "Work")
        fresh.id = labelID
        store.context.insert(fresh)
        try store.context.save()

        attached.apply(to: store.task(t.id)!, only: [.labels])
        #expect(store.task(t.id)?.labels?.map(\.id) == [labelID])
        #expect(store.task(t.id)?.labels?.first === fresh, "the live instance, not a stale object")
    }

    @Test func snapshotResolvesAProjectByIdAfterTheRowWasRebuilt() throws {
        let store = try TaskStore(inMemory: true)
        let p = store.createProject(name: "Acme")
        let projectID = p.id
        let t = store.create(title: "A", project: p)
        let inProject = TaskStore.TaskSnapshot(store.task(t.id)!)
        #expect(inProject.projectID == projectID)
        store.move(t.id, toProject: nil)
        #expect(store.task(t.id)?.project == nil)

        store.context.delete(p)
        try store.context.save()
        let fresh = KProject(name: "Acme", colorHex: "#8224E3", icon: nil, area: nil, sortIndex: 0)
        fresh.id = projectID
        store.context.insert(fresh)
        try store.context.save()

        inProject.apply(to: store.task(t.id)!, only: [.project])
        #expect(store.task(t.id)?.project === fresh)
        #expect(store.task(t.id)?.projectID == projectID)
    }

    /// A project that no longer exists cannot be restored: the row is left as it is, not pointed at
    /// a dead object.
    @Test func snapshotWithAMissingProjectLeavesTheRowAlone() throws {
        let store = try TaskStore(inMemory: true)
        let p = store.createProject(name: "Gone")
        let t = store.create(title: "A", project: p)
        let snap = TaskStore.TaskSnapshot(store.task(t.id)!)
        store.move(t.id, toProject: nil)
        store.context.delete(p)
        try store.context.save()
        snap.apply(to: store.task(t.id)!, only: [.project])
        #expect(store.task(t.id)?.project == nil)
        #expect(store.task(t.id)?.projectID == nil)
    }

    @Test func projectMoveUndoAndRedoRestoreTheMirrorsToo() throws {
        let store = try TaskStore(inMemory: true)
        let area = store.createArea(name: "Biz")
        let p = store.createProject(name: "Acme", area: area)
        let t = store.create(title: "A")

        store.move(t.id, toProject: p)
        #expect(store.task(t.id)?.projectID == p.id)
        #expect(store.task(t.id)?.areaID == area.id)

        store.undo()
        #expect(store.task(t.id)?.project == nil)
        #expect(store.task(t.id)?.projectID == nil)
        #expect(store.task(t.id)?.areaID == nil)

        store.redo()
        #expect(store.task(t.id)?.project?.id == p.id)
        #expect(store.task(t.id)?.projectID == p.id)
        #expect(store.task(t.id)?.areaID == area.id)
    }

    @Test func parentChangeUndoesAndRedoesByIdAndLeavesOtherFieldsAlone() throws {
        let store = try TaskStore(inMemory: true)
        let parent = store.create(title: "Parent")
        let child = store.create(title: "Child")
        store.update(child.id) { $0.parent = parent; $0.parentID = parent.id }
        store.updateNoUndo(child.id) { $0.notes = "agent" }

        store.undo()
        #expect(store.task(child.id)?.parent == nil)
        #expect(store.task(child.id)?.parentID == nil)
        #expect(store.task(child.id)?.notes == "agent")
        store.redo()
        #expect(store.task(child.id)?.parent?.id == parent.id)
        #expect(store.task(child.id)?.parentID == parent.id)
    }

    // MARK: Create origin

    @Test func creatingATaskNotifiesWithItsOrigin() throws {
        let store = try TaskStore(inMemory: true)
        var origins: [String] = []
        let token = NotificationCenter.default.addObserver(forName: .kronosTaskDidCreate, object: nil, queue: nil) { n in
            if let o = n.userInfo?[TaskStore.createOriginKey] as? String { origins.append(o) }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        store.create(title: "typed by the user")
        store.createNoUndo(title: "written by MCP")
        #expect(origins == ["user", "machine"])
    }
}
