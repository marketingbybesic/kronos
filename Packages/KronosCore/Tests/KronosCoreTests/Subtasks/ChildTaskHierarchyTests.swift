import Testing
import Foundation
@testable import KronosCore

/// Subtasks are child KTasks (one level). Every expectation below is written by hand.
@MainActor
@Suite("ChildTaskHierarchyTests")
struct ChildTaskHierarchyTests {

    private func titles(_ ts: [KTask]) -> [String] { ts.map(\.title) }

    // MARK: - Model

    @Test func aChildIsATaskWithAParentAndNeverAListRow() throws {
        let store = try TaskStore(inMemory: true)
        let home = store.createProject(name: "Home")
        let p = store.createNoUndo(title: "P", project: home)
        let c = try #require(store.addSubtask(p.id, title: "c"))
        #expect(c.isSubtask)
        #expect(!p.isSubtask)
        #expect(c.parent?.id == p.id)
        #expect(c.parentID == p.id)
        #expect(c.projectID == home.id, "a child inherits its parent's project")
        #expect(titles(store.allTasks()) == ["P"], "lists never carry a child")
        #expect(Set(titles(store.allTasksIncludingSubtasks())) == ["P", "c"])
        #expect(store.task(c.id)?.title == "c", "every task API reaches a child by id")
        #expect(titles(p.orderedChildren) == ["c"])
        #expect(store.addSubtask(c.id, title: "grandchild") == nil, "one level only")
    }

    @Test func orderedChildrenSkipDeletedAndFollowManualOrder() throws {
        let store = try TaskStore(inMemory: true)
        let p = store.createNoUndo(title: "P")
        let a = try #require(store.addSubtaskNoUndo(p.id, title: "a"))
        let b = try #require(store.addSubtaskNoUndo(p.id, title: "b"))
        let c = try #require(store.addSubtaskNoUndo(p.id, title: "c"))
        store.reorderSubtask(c.id, before: a.id)
        #expect(titles(p.orderedChildren) == ["c", "a", "b"])
        store.deleteSubtask(a.id)
        #expect(titles(p.orderedChildren) == ["c", "b"])
        #expect(p.subtaskProgress.total == 2)
        store.toggleSubtask(b.id)
        #expect(p.subtaskProgress.done == 1)
        #expect(store.task(b.id)?.status == .done)
    }

    // MARK: - setParent table

    private struct World {
        let store: TaskStore
        let work: KProject, home: KProject
        let p: KTask, q: KTask, x: KTask
        let p1: KTask, p2: KTask, x1: KTask, x2: KTask
    }

    /// Work: P(p1, p2), Q.   Home: X(x1, x2).   Manual order P < Q < X.
    private func world() throws -> World {
        let s = try TaskStore(inMemory: true)
        let work = s.createProject(name: "Work")
        let home = s.createProject(name: "Home")
        let p = s.createNoUndo(title: "P", project: work)
        let q = s.createNoUndo(title: "Q", project: work)
        let x = s.createNoUndo(title: "X", project: home)
        let p1 = try #require(s.addSubtaskNoUndo(p.id, title: "p1"))
        let p2 = try #require(s.addSubtaskNoUndo(p.id, title: "p2"))
        let x1 = try #require(s.addSubtaskNoUndo(x.id, title: "x1"))
        let x2 = try #require(s.addSubtaskNoUndo(x.id, title: "x2"))
        return World(store: s, work: work, home: home, p: p, q: q, x: x, p1: p1, p2: p2, x1: x1, x2: x2)
    }

    @Test func nestFlattensChildrenAfterTheRowAndInheritsTheProject() throws {
        let w = try world()
        try w.store.setParent(w.x.id, to: w.p.id, at: .before(w.p2.id))
        #expect(titles(w.p.orderedChildren) == ["p1", "X", "x1", "x2", "p2"])
        for t in [w.x, w.x1, w.x2] {
            #expect(t.parentID == w.p.id)
            #expect(t.projectID == w.work.id, "\(t.title) takes the new parent's project")
        }
        #expect(w.x.orderedChildren.isEmpty, "one level: X kept no children")
        #expect(titles(w.store.allTasks().sorted(by: Ordering.manual)) == ["P", "Q"])
    }

    @Test func promoteKeepsIdFieldsAndProjectAndLandsBehindTheFormerParent() throws {
        let w = try world()
        w.store.setSubtaskDueDay(w.p1.id, SubtaskFixture.day("2026-10-20"))
        w.store.setSubtaskPriority(w.p1.id, .high)
        let id = w.p1.id
        try w.store.setParent(id, to: nil, at: .afterFormerParent)
        let t = try #require(w.store.task(id))
        #expect(t.parentID == nil)
        #expect(t.projectID == w.work.id)
        #expect(SubtaskFixture.iso(t.dueDay) == "2026-10-20")
        #expect(t.priority == .high)
        #expect(titles(w.store.allTasks().sorted(by: Ordering.manual)) == ["P", "p1", "Q", "X"])
        #expect(titles(w.p.orderedChildren) == ["p2"])
    }

    @Test func reparentMovesToTheEndOfTheOtherParentsSteps() throws {
        let w = try world()
        try w.store.setParent(w.p1.id, to: w.x.id, at: .end)
        #expect(titles(w.x.orderedChildren) == ["x1", "x2", "p1"])
        #expect(w.p1.projectID == w.home.id)
        #expect(titles(w.p.orderedChildren) == ["p2"])
    }

    @Test func refusalsChangeNothingAndPushNothing() throws {
        let w = try world()
        let before = SubtaskFixture.dump(w.store)
        let depth = w.store.undoDepth
        let cases: [(UUID, UUID?, TaskNestError)] = [
            (w.p.id, w.p.id, .sameTask),
            (w.q.id, w.p1.id, .parentIsSubtask),
            (w.p.id, w.p1.id, .parentIsSubtask),     // a parent under its own child
            (UUID(), w.p.id, .taskNotFound),
            (w.q.id, UUID(), .parentNotFound),
        ]
        for (id, parent, expected) in cases {
            #expect(throws: expected) { try w.store.setParent(id, to: parent, at: .end) }
        }
        #expect(SubtaskFixture.dump(w.store) == before)
        #expect(w.store.undoDepth == depth)
    }

    @Test func placementsTheRowAlreadyHasAreNoOps() throws {
        let w = try world()
        let before = SubtaskFixture.dump(w.store)
        let depth = w.store.undoDepth
        try w.store.setParent(w.p2.id, to: w.p.id, at: .end)            // already last
        try w.store.setParent(w.p1.id, to: w.p.id, at: .before(w.p2.id)) // already before p2
        w.store.reparentSubtask(w.p1.id, under: w.p.id)                  // current parent
        w.store.reorderSubtask(w.p2.id, before: nil)
        #expect(w.store.undoDepth == depth)
        #expect(SubtaskFixture.dump(w.store) == before)
    }

    @Test func everyMoveIsOneUndoStepRestoringExactlyAndRedoReplays() throws {
        let w = try world()
        let moves: [(String, () throws -> Void)] = [
            ("nest with flatten", { try w.store.setParent(w.x.id, to: w.p.id, at: .end) }),
            ("promote", { try w.store.setParent(w.p2.id, to: nil, at: .afterFormerParent) }),
            ("reparent", { try w.store.setParent(w.x1.id, to: w.q.id, at: .end) }),
            ("reorder", { try w.store.setParent(w.p2.id, to: w.p.id, at: .before(w.p1.id)) }),
        ]
        for (name, move) in moves {
            let before = SubtaskFixture.dump(w.store)
            let depth = w.store.undoDepth
            try move()
            let after = SubtaskFixture.dump(w.store)
            #expect(after != before, "\(name) changed something")
            #expect(w.store.undoDepth == depth + 1, "\(name) is one undo step")
            w.store.undo()
            #expect(SubtaskFixture.dump(w.store) == before, "\(name) undo restores exactly")
            w.store.redo()
            #expect(SubtaskFixture.dump(w.store) == after, "\(name) redo replays")
            w.store.undo()
            #expect(SubtaskFixture.dump(w.store) == before, "\(name) undo again after redo")
        }
    }

    // MARK: - Project/area follow the parent

    @Test func movingAParentMovesItsChildrenAndMovingAChildAwayPromotesIt() throws {
        let w = try world()
        w.store.move(w.p.id, toProject: w.home)
        #expect([w.p, w.p1, w.p2].allSatisfy { $0.projectID == w.home.id })
        w.store.undo()
        #expect([w.p, w.p1, w.p2].allSatisfy { $0.projectID == w.work.id }, "one undo step for all")

        w.store.move(w.x1.id, toProject: w.work)
        #expect(w.x1.parentID == nil, "a child moved to another project becomes a task")
        #expect(w.x1.projectID == w.work.id)
        w.store.undo()
        #expect(w.x1.parentID == w.x.id)
        #expect(w.x1.projectID == w.home.id)
    }

    // MARK: - Delete / restore

    @Test func deletingAParentDeletesItsChildrenAndUndoRestoresThem() throws {
        let w = try world()
        let depth = w.store.undoDepth
        w.store.softDelete(w.p.id)
        #expect(w.store.undoDepth == depth + 1)
        #expect(w.store.task(w.p1.id) == nil)
        #expect(w.store.task(w.p2.id) == nil)
        #expect(w.p1.deletedAt == w.p.deletedAt)
        w.store.undo()
        #expect(titles(w.p.orderedChildren) == ["p1", "p2"])
        #expect(w.store.task(w.p.id) != nil)

        // restore brings back the children deleted with it, not one deleted earlier
        w.store.deleteSubtask(w.p1.id)
        w.store.softDelete(w.p.id)
        w.store.restore(w.p.id)
        #expect(titles(w.p.orderedChildren) == ["p2"])
    }

    @Test func restoringAChildOfADeletedParentRestoresTheParent() throws {
        let w = try world()
        w.store.softDelete(w.x.id)
        w.store.restore(w.x1.id)
        #expect(w.store.task(w.x.id) != nil)
        #expect(titles(w.x.orderedChildren) == ["x1"])
    }

    @Test func purgeHardDeletesChildrenWithTheirParent() throws {
        let w = try world()
        w.store.softDelete(w.x.id)
        w.store.purgeDeletedOlderThan(days: 0, now: Date().addingTimeInterval(60))
        let ids = Set(w.store.allTasksIncludingDeleted().map(\.title))
        #expect(ids == ["P", "Q", "p1", "p2"])
    }

    // MARK: - Recurrence, effective due

    @Test func aRecurringChildRegeneratesUnderTheSameParent() throws {
        let w = try world()
        w.store.update(w.p1.id) {
            $0.recurrenceRule = RecurrenceRule.daily(every: 7, anchor: .fromDueDay).wireFormat
            $0.dueDay = SubtaskFixture.day("2030-01-05")
        }
        let depth = w.store.undoDepth
        w.store.toggleSubtask(w.p1.id)
        #expect(w.store.undoDepth == depth + 1, "completion + successor = one step")
        let kids = w.p.orderedChildren
        #expect(titles(kids) == ["p1", "p2", "p1"])
        let next = try #require(kids.last)
        #expect(next.id != w.p1.id)
        #expect(next.parentID == w.p.id)
        #expect(next.status == .todo)
        #expect(SubtaskFixture.iso(next.dueDay) == "2030-01-12")
        #expect(titles(w.store.allTasks().sorted(by: Ordering.manual)) == ["P", "Q", "X"])
        w.store.undo()
        #expect(titles(w.p.orderedChildren) == ["p1", "p2"])
        #expect(w.store.task(w.p1.id)?.status == .todo)
    }

    @Test func aRecurringParentsSuccessorGetsFreshOpenSteps() throws {
        let w = try world()
        w.store.update(w.x.id) {
            $0.recurrenceRule = RecurrenceRule.daily(every: 1, anchor: .fromDueDay).wireFormat
            $0.dueDay = SubtaskFixture.day("2030-01-05")
        }
        w.store.toggleSubtask(w.x1.id)
        w.store.complete(w.x.id)
        let next = try #require(w.store.allTasks().first { $0.title == "X" && $0.id != w.x.id })
        #expect(titles(next.orderedChildren) == ["x1", "x2"])
        #expect(next.orderedChildren.allSatisfy { $0.status == .todo && $0.parentID == next.id })
        #expect(titles(w.x.orderedChildren) == ["x1", "x2"], "the old instance keeps its own steps")
    }

    @Test func effectiveDueReadsOpenChildren() throws {
        let w = try world()
        let rows: [(own: String?, p1: String?, p1Done: Bool, p2: String?, expected: String?)] = [
            (nil, nil, false, nil, nil),
            ("2026-10-10", nil, false, nil, "2026-10-10"),
            (nil, "2026-10-08", false, nil, "2026-10-08"),
            ("2026-10-10", "2026-10-08", false, "2026-10-09", "2026-10-08"),
            ("2026-10-10", "2026-10-08", true, "2026-10-09", "2026-10-09"),
            ("2026-10-05", "2026-10-08", false, nil, "2026-10-05"),
        ]
        for r in rows {
            w.p.dueDay = r.own.map(SubtaskFixture.day)
            w.p1.dueDay = r.p1.map(SubtaskFixture.day)
            w.p1.isDone = r.p1Done
            w.p2.dueDay = r.p2.map(SubtaskFixture.day)
            #expect(SubtaskFixture.iso(w.p.effectiveDue) == r.expected, "\(r)")
        }
    }
}
