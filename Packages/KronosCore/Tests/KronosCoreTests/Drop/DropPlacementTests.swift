import Testing
import Foundation
@testable import KronosCore

private let A = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
private let B = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
private let C = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!
private let Z = UUID(uuidString: "00000000-0000-0000-0000-0000000000FF")!

// Manual order [A, B, C] with sortIndex 0, 1024, 2048.
private let order = [A, B, C]
private let index: [UUID: Double] = [A: 0, B: 1024, C: 2048]

@Suite("Drop placement arithmetic")
struct DropPlacementTests {

    private struct SlotCase {
        let name: String
        let before: UUID?
        let excluding: UUID?
        let lo: Double?
        let hi: Double?
        let value: Double
    }

    @Test("slot and value table: before the first, between, before the last, at the end")
    func slotTable() {
        let table: [SlotCase] = [
            .init(name: "C before A", before: A, excluding: C, lo: nil, hi: 0, value: -1024),
            .init(name: "A before C", before: C, excluding: A, lo: 1024, hi: 2048, value: 1536),
            .init(name: "C before B", before: B, excluding: C, lo: 0, hi: 1024, value: 512),
            .init(name: "A to the end", before: nil, excluding: A, lo: 2048, hi: nil, value: 3072),
            .init(name: "C to the end excluding nothing", before: nil, excluding: nil, lo: 2048, hi: nil, value: 3072),
            .init(name: "new row before A (nothing excluded)", before: A, excluding: nil, lo: nil, hi: 0, value: -1024),
            .init(name: "new row before B (nothing excluded)", before: B, excluding: nil, lo: 0, hi: 1024, value: 512),
        ]
        for c in table {
            let slot = DropPlacement.slot(before: c.before, order: order, excluding: c.excluding) { index[$0] }
            #expect(slot?.lo == c.lo, "\(c.name) lo")
            #expect(slot?.hi == c.hi, "\(c.name) hi")
            #expect(DropPlacement.indexBetween(lo: slot?.lo, hi: slot?.hi) == c.value, "\(c.name) value")
        }
    }

    @Test("a target that is not in the list gives no slot; an empty list gives index 0")
    func unknownTarget() {
        #expect(DropPlacement.slot(before: Z, order: order, excluding: nil) { index[$0] } == nil)
        #expect(DropPlacement.indexBetween(lo: nil, hi: nil) == 0)
        let empty = DropPlacement.slot(before: nil, order: [], excluding: nil) { index[$0] }
        #expect(empty?.lo == nil && empty?.hi == nil)
    }

    @Test("no-op detection: already directly before the target, already last, or the target itself")
    func noOpTable() {
        #expect(DropPlacement.isNoOp(moving: B, before: C, order: order))
        #expect(DropPlacement.isNoOp(moving: A, before: B, order: order))
        #expect(DropPlacement.isNoOp(moving: C, before: nil, order: order))
        #expect(DropPlacement.isNoOp(moving: B, before: B, order: order))
        #expect(!DropPlacement.isNoOp(moving: A, before: C, order: order))
        #expect(!DropPlacement.isNoOp(moving: C, before: A, order: order))
        #expect(!DropPlacement.isNoOp(moving: A, before: nil, order: order))
    }

    @Test("positive control: a placement that forgets to exclude the moving row is caught")
    func controlNotExcluding() {
        // B moved to the slot before C: its neighbours are A (0) and C (2048), so 1024. If B stayed in
        // the list as its own neighbour the value would come out as 1536.
        let right = DropPlacement.slot(before: C, order: order, excluding: B) { index[$0] }
        let wrong = DropPlacement.slot(before: C, order: order, excluding: nil) { index[$0] }
        #expect(DropPlacement.indexBetween(lo: right?.lo, hi: right?.hi) == 1024)
        #expect(DropPlacement.indexBetween(lo: wrong?.lo, hi: wrong?.hi) == 1536)
        #expect(DropPlacement.indexBetween(lo: right?.lo, hi: right?.hi) != DropPlacement.indexBetween(lo: wrong?.lo, hi: wrong?.hi))
    }
}

// MARK: - The store operations the list commit relies on

@MainActor
@Suite("Drop commit on the store")
struct DropCommitStoreTests {

    private func snapshot(_ store: TaskStore) -> [String] {
        var lines: [String] = []
        for t in store.allTasks() {
            lines.append("T|\(t.id)|\(t.title)|\(t.sortIndex)|\(t.statusRaw)|\(t.notes)")
            for s in t.orderedSubtasks { lines.append("S|\(s.id)|\(t.id)|\(s.title)|\(s.sortIndex)|\(s.isDone)|\(s.priorityRaw)") }
        }
        return lines.sorted()
    }

    @Test("promote a step and place it before a task: ONE undo step, exact restore")
    func promoteAndPlaceIsOneStep() throws {
        let store = try TaskStore(inMemory: true)
        let a = store.create(title: "A")
        _ = store.create(title: "B")
        let c = store.create(title: "C")
        let step = try #require(store.addSubtask(c.id, title: "step"))
        step.priorityRaw = 2
        let before = snapshot(store)
        let depth = store.undoDepth

        var created: KTask?
        store.groupedUndo("Promote Step") {
            created = store.promoteSubtaskToTask(step.id)
            if let created {
                let slot = DropPlacement.slot(before: a.id, order: [a.id, store.allTasks().first { $0.title == "B" }!.id, c.id],
                                              excluding: created.id) { store.task($0)?.sortIndex }
                let value = DropPlacement.indexBetween(lo: slot?.lo, hi: slot?.hi)
                store.update(created.id) { $0.sortIndex = value }
            }
        }
        let promoted = try #require(created)
        #expect(store.undoDepth - depth == 1)
        #expect(promoted.title == "step" && promoted.priorityRaw == 2)
        #expect(KTaskSorter.sorted(store.allTasks(), by: [.asc(.manual)]).first?.title == "step")
        #expect((store.task(c.id)?.orderedSubtasks.count ?? -1) == 0)

        store.undo()
        #expect(snapshot(store) == before)
        #expect(store.task(c.id)?.orderedSubtasks.first?.id == step.id)
    }

    @Test("move a step under another task at a position: ONE undo step, exact restore")
    func moveStepIsOneStep() throws {
        let store = try TaskStore(inMemory: true)
        let a = store.create(title: "A")
        let b = store.create(title: "B")
        let a1 = try #require(store.addSubtask(a.id, title: "a1"))
        _ = try #require(store.addSubtask(b.id, title: "b1"))
        let b2 = try #require(store.addSubtask(b.id, title: "b2"))
        let before = snapshot(store)
        let depth = store.undoDepth

        store.groupedUndo("Move Step") {
            store.reparentSubtask(a1.id, under: b.id)
            store.reorderSubtask(a1.id, before: b2.id)
        }
        #expect(store.undoDepth - depth == 1)
        #expect(store.task(b.id)?.orderedSubtasks.map(\.title) == ["b1", "a1", "b2"])
        #expect(store.task(a.id)?.orderedSubtasks.isEmpty == true)

        store.undo()
        #expect(snapshot(store) == before)
    }

    @Test("nest: one undo step with exact restore; a recurring task is refused with no step")
    func nestOneStepAndRefusal() throws {
        let store = try TaskStore(inMemory: true)
        let a = store.create(title: "A")
        let b = store.create(title: "B")
        let c = store.create(title: "C")
        let b1 = try #require(store.addSubtask(b.id, title: "b1"))
        let before = snapshot(store)
        var depth = store.undoDepth

        try store.makeTaskSubtaskOf(b.id, parentID: a.id)
        #expect(store.undoDepth - depth == 1)
        // Subtasks are tasks now: B is the same row (same id) with a parent, not a new step row.
        #expect(store.task(b.id)?.parentID == a.id)
        #expect(store.task(a.id)?.orderedSubtasks.map(\.title) == ["B", "b1"])
        store.undo()
        #expect(snapshot(store) == before)

        // CHANGED: a recurring task now nests; the remaining refusal is a subtask as target.
        depth = store.undoDepth
        let refused = snapshot(store)
        #expect(throws: TaskNestError.parentIsSubtask) { try store.makeTaskSubtaskOf(c.id, parentID: b1.id) }
        #expect(store.undoDepth == depth)
        #expect(snapshot(store) == refused)
    }

    @Test("positive control: without the group, promote plus placement is two undo steps")
    func controlUngroupedIsTwoSteps() throws {
        let store = try TaskStore(inMemory: true)
        let a = store.create(title: "A")
        let step = try #require(store.addSubtask(a.id, title: "step"))
        let depth = store.undoDepth
        let created = try #require(store.promoteSubtaskToTask(step.id))
        store.update(created.id) { $0.sortIndex = -1024 }
        #expect(store.undoDepth - depth == 2, "the group is what makes the drop a single undo step")
    }
}
