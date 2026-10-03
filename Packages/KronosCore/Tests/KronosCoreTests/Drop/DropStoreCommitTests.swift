import Testing
import Foundation
@testable import KronosCore

/// The planned drop commands applied to a real store: the hierarchy the user ends up with, the one
/// undo step each, and the one-level rule. Expected orders are written by hand.
///
/// World: top level P(p1, p2), Q, X(x1, x2) in that manual order.
@MainActor
@Suite("DropStoreCommitTests")
struct DropStoreCommitTests {

    @MainActor private struct World {
        let store: TaskStore
        let p: KTask, q: KTask, x: KTask
        let p1: KTask, p2: KTask, x1: KTask, x2: KTask

        func top() -> [String] { KTaskSorter.sorted(store.allTasks(), by: [.asc(.manual)]).map(\.title) }
        func kids(_ t: KTask) -> [String] { store.children(of: t.id).map(\.title) }
    }

    private func world() throws -> World {
        let s = try TaskStore(inMemory: true)
        let p = s.createNoUndo(title: "P")
        let q = s.createNoUndo(title: "Q")
        let x = s.createNoUndo(title: "X")
        let p1 = try #require(s.addSubtaskNoUndo(p.id, title: "p1"))
        let p2 = try #require(s.addSubtaskNoUndo(p.id, title: "p2"))
        let x1 = try #require(s.addSubtaskNoUndo(x.id, title: "x1"))
        let x2 = try #require(s.addSubtaskNoUndo(x.id, title: "x2"))
        return World(store: s, p: p, q: q, x: x, p1: p1, p2: p2, x1: x1, x2: x2)
    }

    /// The store operation each command stands for (the same mapping the list's commit code uses).
    private func apply(_ c: DropCommand, to store: TaskStore) throws {
        func placement(_ before: UUID?) -> KNestPlacement { before.map { .before($0) } ?? .end }
        switch c {
        case .nestTask(let id, let parent, let before): try store.setParent(id, to: parent, at: placement(before))
        case .moveSubtask(let id, let parent, let before): try store.setParent(id, to: parent, at: placement(before))
        case .reorderSubtask(let id, let before): store.reorderChild(id, before: before)
        case .promoteSubtask(let id, let before): try store.setParent(id, to: nil, at: placement(before))
        default: Issue.record("not a hierarchy command: \(c)")
        }
    }

    @Test("a task dropped onto a child becomes its sibling right after it, one undo step")
    func nestOntoChild() throws {
        let w = try world()
        let depth = w.store.undoDepth
        try apply(.nestTask(w.q.id, under: w.p.id, before: w.p2.id), to: w.store)
        #expect(w.kids(w.p) == ["p1", "Q", "p2"])
        #expect(w.top() == ["P", "X"])
        #expect(w.store.undoDepth == depth + 1)
        w.store.undo()
        #expect(w.kids(w.p) == ["p1", "p2"])
        #expect(w.top() == ["P", "Q", "X"])
        #expect(w.store.task(w.q.id)?.parentID == nil)
    }

    @Test("a task with children nests and flattens: its children follow as siblings, no grandchild")
    func nestFlattens() throws {
        let w = try world()
        try apply(.nestTask(w.x.id, under: w.p.id, before: nil), to: w.store)
        #expect(w.kids(w.p) == ["p1", "p2", "X", "x1", "x2"])
        #expect(w.kids(w.x).isEmpty, "X no longer has children of its own")
        #expect(w.store.task(w.x1.id)?.parentID == w.p.id)
        #expect(w.top() == ["P", "Q"])
        w.store.undo()
        #expect(w.kids(w.x) == ["x1", "x2"])
        #expect(w.kids(w.p) == ["p1", "p2"])
        #expect(w.top() == ["P", "Q", "X"])
        #expect(w.store.task(w.x1.id)?.parentID == w.x.id)
    }

    @Test("a child dropped onto a child of another task lands after it under that parent")
    func moveChildAfterChild() throws {
        let w = try world()
        try apply(.moveSubtask(w.x2.id, under: w.p.id, before: w.p2.id), to: w.store)
        #expect(w.kids(w.p) == ["p1", "x2", "p2"])
        #expect(w.kids(w.x) == ["x1"])
        w.store.undo()
        #expect(w.kids(w.p) == ["p1", "p2"])
        #expect(w.kids(w.x) == ["x1", "x2"])
    }

    @Test("a child promoted between tasks keeps its row and lands at the line")
    func promoteBetween() throws {
        let w = try world()
        try apply(.promoteSubtask(w.x2.id, before: w.q.id), to: w.store)
        #expect(w.top() == ["P", "x2", "Q", "X"])
        #expect(w.store.task(w.x2.id)?.id == w.x2.id)
        #expect(w.kids(w.x) == ["x1"])
        w.store.undo()
        #expect(w.top() == ["P", "Q", "X"])
        #expect(w.kids(w.x) == ["x1", "x2"])
    }

    @Test("reordering children is one undo step and a drop where it already is pushes nothing")
    func reorderAndNoOp() throws {
        let w = try world()
        let depth = w.store.undoDepth
        try apply(.reorderSubtask(w.p1.id, before: w.p2.id), to: w.store)   // already directly before p2
        #expect(w.store.undoDepth == depth)
        try apply(.reorderSubtask(w.p2.id, before: w.p1.id), to: w.store)
        #expect(w.kids(w.p) == ["p2", "p1"])
        #expect(w.store.undoDepth == depth + 1)
        w.store.undo()
        #expect(w.kids(w.p) == ["p1", "p2"])
    }

    @Test("a recurring or calendar-linked task nests like any other")
    func recurringNests() throws {
        let w = try world()
        w.store.update(w.q.id) { $0.recurrenceRule = "FREQ=WEEKLY" }
        try apply(.nestTask(w.q.id, under: w.p.id, before: nil), to: w.store)
        #expect(w.kids(w.p) == ["p1", "p2", "Q"])
        #expect(w.store.task(w.q.id)?.recurrenceRule == "FREQ=WEEKLY", "nothing is lost on nesting")
    }

    @Test("a child cannot become a parent: nesting under a child is refused and changes nothing")
    func oneLevelOnly() throws {
        let w = try world()
        let depth = w.store.undoDepth
        #expect(throws: TaskNestError.parentIsSubtask) { try w.store.setParent(w.q.id, to: w.p1.id) }
        #expect(w.store.undoDepth == depth)
        #expect(w.top() == ["P", "Q", "X"])
    }

    @Test("addChild registers one undo step and inherits the parent")
    func addChildOneStep() throws {
        let w = try world()
        let depth = w.store.undoDepth
        let c = try #require(w.store.addChild(to: w.q.id, title: "q1"))
        #expect(w.store.undoDepth == depth + 1)
        #expect(c.parentID == w.q.id)
        #expect(w.kids(w.q) == ["q1"])
        w.store.undo()
        #expect(w.kids(w.q).isEmpty)
    }
}
