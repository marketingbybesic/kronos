import Foundation
import SwiftData
import Testing
@testable import KronosCore

/// A move rewrites at most three rows: itself, and its two direct neighbours only when their
/// gap ran out. Plans written out by hand; the store runs hundreds of adversarial moves.
@MainActor
@Suite("NeighbourPlacementTests")
struct NeighbourPlacementTests {

    static let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    static let b = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    static let c = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!
    static let d = UUID(uuidString: "00000000-0000-0000-0000-00000000000D")!

    /// (rows, slot, expected index, expected neighbours)
    static let plans: [([(id: UUID, idx: Double)], Int, Double, [UUID: Double])] = [
        ([], 0, 0, [:]),
        ([(a, 0)], 0, -1024, [:]),
        ([(a, 0)], 1, 1024, [:]),
        ([(a, 0), (b, 1024)], 1, 512, [:]),
        ([(a, 0), (b, 1024)], 2, 2048, [:]),
        // b and c tie: no value fits between them, so b and c spread inside (a, d).
        ([(a, 0), (b, 1), (c, 1), (d, 2048)], 2, 1024, [b: 512, c: 1536]),
        // Same at the start of the list: the lower bound is two steps below the window.
        ([(b, 5), (c, 5), (d, 10)], 1, -1016.5, [b: -1529.75, c: -503.25]),
        // A gap far below the margin also counts as used up.
        ([(a, 0), (b, 100), (c, 100 + 1e-9), (d, 300)], 2, 150, [b: 75, c: 225]),
    ]

    @Test func plansFollowTheTable() {
        for (rows, slot, index, neighbours) in Self.plans {
            let plan = NeighbourPlacement.plan(rows: rows, slot: slot)
            #expect(plan.index == index, "rows=\(rows.map(\.idx)) slot=\(slot)")
            #expect(plan.neighbours == neighbours, "rows=\(rows.map(\.idx)) slot=\(slot)")
        }
    }

    // MARK: Store

    /// Every row's index, to count what one move rewrote.
    private func indices(_ s: TaskStore) -> [UUID: Double] {
        Dictionary(uniqueKeysWithValues: s.allTasks().map { ($0.id, $0.sortIndex) })
    }

    private func displayOrder(_ s: TaskStore) -> [UUID] {
        s.allTasks().sorted(by: Ordering.manual).map(\.id)
    }

    /// 120 drops into the same spot (always right after the first row, then always right before
    /// the row dropped last): the order is exactly what was dropped, and no drop rewrites more
    /// than 3 rows.
    @Test(arguments: [false, true])
    func repeatedDropsIntoOneGapRewriteAtMostThreeRows(clusterOnLast: Bool) throws {
        let s = try TaskStore(inMemory: true)
        var order: [UUID] = (0..<5).map { s.create(title: "Row \($0)").id }
        var lastDropped: UUID?
        var maxRewritten = 0
        var respaced = 0
        for i in 0..<120 {
            let new = s.create(title: "Dropped \(i)").id
            order.append(new)
            let target = clusterOnLast ? (lastDropped ?? order[1]) : order[1]
            let before = indices(s)
            #expect(s.moveTask(new, before: target, inOrder: order))
            order.removeAll { $0 == new }
            order.insert(new, at: order.firstIndex(of: target)!)
            let after = indices(s)
            let rewritten = after.filter { before[$0.key] != $0.value }.count
            maxRewritten = max(maxRewritten, rewritten)
            if rewritten > 1 { respaced += 1 }
            #expect(rewritten <= 3, "drop \(i) rewrote \(rewritten) rows")
            #expect(displayOrder(s) == order, "order wrong after drop \(i)")
            lastDropped = new
        }
        #expect(respaced > 0)            // the gaps did run out and were respaced locally
        #expect(maxRewritten == 3)
    }

    /// The respacing move is one undo step that restores every row it touched.
    @Test func respacingMoveUndoesInOneStep() throws {
        let s = try TaskStore(inMemory: true)
        let rows = (0..<4).map { s.create(title: "R\($0)") }
        s.updateNoUndo(rows[1].id) { $0.sortIndex = 1 }
        s.updateNoUndo(rows[2].id) { $0.sortIndex = 1 }
        s.updateNoUndo(rows[0].id) { $0.sortIndex = 0 }
        s.updateNoUndo(rows[3].id) { $0.sortIndex = 2048 }
        let mover = s.create(title: "Mover")
        let order = [rows[0].id, rows[1].id, rows[2].id, rows[3].id, mover.id]
        let before = indices(s)
        let depth = s.undoDepth
        #expect(s.moveTask(mover.id, before: rows[2].id, inOrder: order))
        #expect(s.undoDepth == depth + 1)
        #expect(displayOrder(s) == [rows[0].id, rows[1].id, mover.id, rows[2].id, rows[3].id])
        s.undo()
        #expect(indices(s) == before)
        // Dropping where it already is pushes nothing.
        #expect(!s.moveTask(mover.id, before: nil, inOrder: order))
        #expect(s.undoDepth == depth)
    }

    /// Steps reordered into a tie: at most 3 rows rewritten, order right, one undo step.
    @Test func stepReorderIntoATie() throws {
        let s = try TaskStore(inMemory: true)
        let parent = s.create(title: "Parent")
        let steps = (0..<5).compactMap { s.addChild(to: parent.id, title: "S\($0)") }
        for (i, idx) in [0.0, 5, 5, 5, 4096].enumerated() { s.updateNoUndo(steps[i].id) { $0.sortIndex = idx } }
        let shown = s.children(of: parent.id).map(\.id)
        let before = Dictionary(uniqueKeysWithValues: steps.map { ($0.id, $0.sortIndex) })
        s.reorderChild(steps[4].id, before: shown[2])
        let after = Dictionary(uniqueKeysWithValues: s.children(of: parent.id).map { ($0.id, $0.sortIndex) })
        #expect(after.filter { before[$0.key] != $0.value }.count <= 3)
        var expected = shown.filter { $0 != steps[4].id }
        expected.insert(steps[4].id, at: expected.firstIndex(of: shown[2])!)
        #expect(s.children(of: parent.id).map(\.id) == expected)
        s.undo()
        #expect(Dictionary(uniqueKeysWithValues: s.children(of: parent.id).map { ($0.id, $0.sortIndex) }) == before)
    }

    /// Projects and saved views use the same local respacing.
    @Test func projectAndViewReorderIntoATie() throws {
        let s = try TaskStore(inMemory: true)
        let ps = (0..<4).map { s.createProject(name: "P\($0)") }
        for (i, idx) in [0.0, 7, 7, 900].enumerated() { ps[i].sortIndex = idx }
        try s.context.save()
        let shown = s.allProjects(includeArchived: true).map(\.id)
        s.reorderProject(shown[3], before: shown[2])
        let now = s.allProjects(includeArchived: true).map(\.id)
        #expect(now == [shown[0], shown[1], shown[3], shown[2]])

        let vs = (0..<4).map { s.createSavedView(name: "V\($0)", filter: KFilter()) }
        for (i, idx) in [0.0, 3, 3, 500].enumerated() { vs[i].sortIndex = idx }
        try s.context.save()
        let shownViews = s.allSavedViews().map(\.id)
        s.reorderSavedView(shownViews[3], before: shownViews[2])
        #expect(s.allSavedViews().map(\.id) == [shownViews[0], shownViews[1], shownViews[3], shownViews[2]])
        s.undo()
        #expect(s.allSavedViews().map(\.id) == shownViews)
    }
}
