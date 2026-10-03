import Testing
import Foundation
@testable import KronosCore

// Hand-written layout for the resolver and planner tables:
//
//   A   y   0..40          task
//   (gap 40..44)
//   B   y  44..84          task with two steps
//   B1  y  88..116         step (28 tall)
//   B2  y 120..148         step
//   C   y 152..192         task
//
// Task order [A, B, C]; B's step order [B1, B2]. Every expected value below is read off that
// picture, not computed from the resolver.

private let A = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
private let B = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
private let C = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!
private let B1 = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
private let B2 = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
private let X = UUID(uuidString: "00000000-0000-0000-0000-0000000000F1")!   // a step of C, not on screen

private let rows: [DropRow] = [
    DropRow(id: A, minY: 0, maxY: 40),
    DropRow(id: B, minY: 44, maxY: 84),
    DropRow(id: B1, parentID: B, minY: 88, maxY: 116),
    DropRow(id: B2, parentID: B, minY: 120, maxY: 148),
    DropRow(id: C, minY: 152, maxY: 192),
]
private let order = DropOrder(tasks: [A, B, C], subtasks: [B: [B1, B2]])

private struct ResolveCase {
    let name: String
    let subject: DropSubject
    let y: Double
    var hold: Double = 0
    var manual = true
    let zone: DropZone
    var heldZone: DropZone = .none
    var rowID: UUID? = nil
    var taskID: UUID? = nil
    var before: UUID?? = nil          // .some(nil) = expects "at the end"
    var lineY: Double?? = nil         // .some(nil) = expects a hidden line
    var command: DropCommand? = nil
    var endOfList = false
}

private let resolveTable: [ResolveCase] = [
    // a task dragged within the list
    .init(name: "C onto A top edge", subject: .task(C), y: 2, zone: .insertAbove, rowID: A, before: .some(A), lineY: .some(0), command: .moveTask(C, before: A)),
    .init(name: "C onto A bottom edge", subject: .task(C), y: 38, zone: .insertBelow, rowID: A, before: .some(B), lineY: .some(40), command: .moveTask(C, before: B)),
    .init(name: "C onto A centre, no hold yet", subject: .task(C), y: 20, zone: .none, heldZone: .nest, rowID: A, command: .none),
    .init(name: "C onto A centre, held", subject: .task(C), y: 20, hold: 0.7, zone: .nest, rowID: A, taskID: A, command: .nestTask(C, under: A, before: nil)),
    .init(name: "gap, nearer the row above", subject: .task(C), y: 41, zone: .insertBelow, rowID: A, before: .some(B), lineY: .some(40)),
    .init(name: "gap exactly in the middle goes to the row above", subject: .task(C), y: 42, zone: .insertBelow, rowID: A, before: .some(B), lineY: .some(40)),
    .init(name: "gap, nearer the row below", subject: .task(C), y: 43, zone: .insertAbove, rowID: B, before: .some(B), lineY: .some(44)),
    .init(name: "above the first row", subject: .task(C), y: -12, zone: .insertAbove, rowID: A, before: .some(A), lineY: .some(0)),
    .init(name: "empty space after the last row", subject: .task(A), y: 230, zone: .insertBelow, rowID: C, before: .some(nil), lineY: .some(192), command: .moveTask(A, before: nil), endOfList: true),
    .init(name: "own row at the end of the list", subject: .task(C), y: 230, zone: .none, rowID: C, endOfList: true),
    .init(name: "empty space, sorted list: a task move means nothing", subject: .task(A), y: 230, manual: false, zone: .none, rowID: C, endOfList: true),
    .init(name: "empty space, sorted list: a promoted step still lands, line hidden", subject: .subtask(B1, parent: B), y: 230, manual: false, zone: .insertBelow, rowID: C, lineY: .some(nil), command: .promoteSubtask(B1, before: nil), endOfList: true),
    .init(name: "empty space, sorted list: external still creates, line hidden", subject: .external, y: 230, manual: false, zone: .insertBelow, rowID: C, lineY: .some(nil), command: .createTask(before: nil), endOfList: true),
    // a task is never a target for itself or its own steps
    .init(name: "B onto its own step", subject: .task(B), y: 102, hold: 0.7, zone: .none, rowID: B1),
    .init(name: "B onto itself", subject: .task(B), y: 64, hold: 0.7, zone: .none, rowID: B),
    // dropping a task onto a child row: it becomes that child's sibling under the same parent, directly after it
    .init(name: "A onto step B1 centre, held: sibling after B1", subject: .task(A), y: 102, hold: 0.7, zone: .nest, rowID: B1, taskID: B, before: .some(B2), command: .nestTask(A, under: B, before: B2)),
    .init(name: "A onto last step B2 centre, held: sibling at the end", subject: .task(A), y: 134, hold: 0.7, zone: .nest, rowID: B2, taskID: B, before: .some(nil), command: .nestTask(A, under: B, before: nil)),
    .init(name: "A onto step B1 centre, no hold yet", subject: .task(A), y: 102, zone: .none, heldZone: .nest, rowID: B1, command: .none),
    .init(name: "B (has steps) onto C centre, held: nests, steps follow in the store", subject: .task(B), y: 172, hold: 0.7, zone: .nest, rowID: C, taskID: C, before: .some(nil), command: .nestTask(B, under: C, before: nil)),
    .init(name: "A over a step edge does nothing", subject: .task(A), y: 90, hold: 0.7, zone: .none, rowID: B1),
    // sorted list: no level-0 order, nest still works
    .init(name: "sorted: C onto A top edge", subject: .task(C), y: 2, manual: false, zone: .none, rowID: A),
    .init(name: "sorted: C onto A centre held", subject: .task(C), y: 20, hold: 0.7, manual: false, zone: .nest, rowID: A, command: .nestTask(C, under: A, before: nil)),
    // a step dragged
    .init(name: "B1 reorders below B2", subject: .subtask(B1, parent: B), y: 146, zone: .insertBelow, rowID: B2, taskID: B, before: .some(nil), lineY: .some(148), command: .reorderSubtask(B1, before: nil)),
    .init(name: "B2 reorders above B1", subject: .subtask(B2, parent: B), y: 90, zone: .insertAbove, rowID: B1, taskID: B, before: .some(B1), lineY: .some(88), command: .reorderSubtask(B2, before: B1)),
    .init(name: "step order line stays in a sorted list", subject: .subtask(B2, parent: B), y: 90, manual: false, zone: .insertAbove, lineY: .some(88), command: .reorderSubtask(B2, before: B1)),
    .init(name: "B1 onto itself", subject: .subtask(B1, parent: B), y: 100, hold: 0.7, zone: .none, rowID: B1),
    .init(name: "B1 promoted above A", subject: .subtask(B1, parent: B), y: 2, zone: .insertAbove, rowID: A, before: .some(A), lineY: .some(0), command: .promoteSubtask(B1, before: A)),
    .init(name: "B1 promoted between B and C", subject: .subtask(B1, parent: B), y: 153, zone: .insertAbove, rowID: C, before: .some(C), lineY: .some(152), command: .promoteSubtask(B1, before: C)),
    .init(name: "B1 promoted above its own parent", subject: .subtask(B1, parent: B), y: 46, zone: .insertAbove, rowID: B, before: .some(B), command: .promoteSubtask(B1, before: B)),
    .init(name: "B1 promoted at the end of an empty area", subject: .subtask(B1, parent: B), y: 260, zone: .insertBelow, rowID: C, before: .some(nil), command: .promoteSubtask(B1, before: nil), endOfList: true),
    .init(name: "B1 onto C centre, held: moves under C", subject: .subtask(B1, parent: B), y: 172, hold: 0.7, zone: .moveUnder, rowID: C, taskID: C, command: .moveSubtask(B1, under: C, before: nil)),
    .init(name: "B1 onto C centre, no hold", subject: .subtask(B1, parent: B), y: 172, zone: .none, heldZone: .moveUnder, rowID: C),
    .init(name: "B1 onto its own parent centre, held", subject: .subtask(B1, parent: B), y: 64, hold: 0.7, zone: .none, rowID: B),
    .init(name: "X (a step of C) onto step B1 centre, held: sibling after B1 under B", subject: .subtask(X, parent: C), y: 102, hold: 0.7, zone: .moveUnder, rowID: B1, taskID: B, before: .some(B2), command: .moveSubtask(X, under: B, before: B2)),
    .init(name: "X onto last step B2 centre, held: sibling at the end of B", subject: .subtask(X, parent: C), y: 134, hold: 0.7, zone: .moveUnder, rowID: B2, taskID: B, before: .some(nil), command: .moveSubtask(X, under: B, before: nil)),
    .init(name: "B1 onto sibling B2 centre, held: nothing (same parent)", subject: .subtask(B1, parent: B), y: 134, hold: 0.7, zone: .none, rowID: B2),
    .init(name: "X (a step of C) lands after B2", subject: .subtask(X, parent: C), y: 146, zone: .insertBelow, rowID: B2, taskID: B, before: .some(nil), command: .moveSubtask(X, under: B, before: nil)),
    .init(name: "X (a step of C) lands before B1", subject: .subtask(X, parent: C), y: 90, zone: .insertAbove, rowID: B1, before: .some(B1), command: .moveSubtask(X, under: B, before: B1)),
    // external items
    .init(name: "external between A and B creates a task before B", subject: .external, y: 38, zone: .insertBelow, rowID: A, before: .some(B), lineY: .some(40), command: .createTask(before: B)),
    .init(name: "external above everything", subject: .external, y: 1, zone: .insertAbove, rowID: A, before: .some(A), command: .createTask(before: A)),
    .init(name: "external in empty space appends", subject: .external, y: 300, zone: .insertBelow, rowID: C, before: .some(nil), command: .createTask(before: nil), endOfList: true),
    .init(name: "external sorted: still creates, line hidden", subject: .external, y: 2, manual: false, zone: .insertAbove, before: .some(A), lineY: .some(nil), command: .createTask(before: A)),
    .init(name: "external onto B centre, no hold", subject: .external, y: 64, zone: .none, heldZone: .attachLink, rowID: B, command: .none),
    .init(name: "external onto B centre, held", subject: .external, y: 64, hold: 0.7, zone: .attachLink, rowID: B, taskID: B, command: .attach(rowID: B, isSubtask: false)),
    .init(name: "external onto a step, held", subject: .external, y: 134, hold: 0.7, zone: .attachLink, rowID: B2, taskID: B, command: .attach(rowID: B2, isSubtask: true)),
    .init(name: "external over a step edge", subject: .external, y: 90, hold: 0.7, zone: .none, rowID: B1),
]

private func check(_ c: ResolveCase, hold: Double? = nil, manual: Bool? = nil) -> [String] {
    guard let r = DropResolver.resolve(rows: rows, pointerY: c.y, subject: c.subject, order: order,
                                       holdSeconds: hold ?? c.hold, isManualSort: manual ?? c.manual) else {
        return ["resolved nothing"]
    }
    var problems: [String] = []
    if r.zone != c.zone { problems.append("zone \(r.zone) != \(c.zone)") }
    if r.heldZone != c.heldZone { problems.append("heldZone \(r.heldZone) != \(c.heldZone)") }
    if let id = c.rowID, r.rowID != id { problems.append("row") }
    if let id = c.taskID, r.taskID != id { problems.append("task") }
    if let before = c.before, r.before != before { problems.append("before \(String(describing: r.before)) != \(String(describing: before))") }
    if let line = c.lineY, r.lineY != line { problems.append("lineY \(String(describing: r.lineY)) != \(String(describing: line))") }
    if r.isEndOfList != c.endOfList { problems.append("endOfList") }
    if let want = c.command {
        let got = DropPlanner.command(for: r, subject: c.subject)
        if got != want { problems.append("command \(got) != \(want)") }
    }
    return problems
}

@Suite("Drop resolver and planner")
struct DropResolverTests {

    @Test("resolve table: row, zone, line, landing place and command for every drag in the layout")
    func resolveTableMatches() {
        for c in resolveTable {
            let problems = check(c)
            #expect(problems.isEmpty, "\(c.name): \(problems.joined(separator: "; "))")
        }
    }

    @Test("no rows, no decision")
    func noRows() {
        #expect(DropResolver.resolve(rows: [], pointerY: 10, subject: .external, order: DropOrder(tasks: []),
                                     holdSeconds: 1, isManualSort: true) == nil)
    }

    @Test("an unrealised tail is not mistaken for the end of the list")
    func lazyTail() {
        // Only A and B are realised; C exists in the order. A pointer under B must not claim "end".
        let partial = [DropRow(id: A, minY: 0, maxY: 40), DropRow(id: B, minY: 44, maxY: 84)]
        let r = DropResolver.resolve(rows: partial, pointerY: 120, subject: .external, order: order,
                                     holdSeconds: 0, isManualSort: true)
        #expect(r?.isEndOfList == false)
        #expect(r?.rowID == B)
        #expect(r?.zone == .insertBelow)
        #expect(r?.before == C)
    }

    /// CHANGED EXPECTATION (subtasks became tasks): the planner never refuses a nest. Recurring and
    /// calendar tasks nest, and a child row as target means "sibling under the same parent", so a
    /// grandchild cannot be planned.
    @Test("nest onto a child row targets the parent, never the child")
    func nestNeverTargetsAChild() {
        for y in [96.0, 102.0, 108.0, 128.0, 134.0, 140.0] {
            let r = DropResolver.resolve(rows: rows, pointerY: y, subject: .task(A), order: order, holdSeconds: 0.7, isManualSort: true)!
            guard case .nestTask(let id, let under, _) = DropPlanner.command(for: r, subject: .task(A)) else {
                Issue.record("y=\(y): expected a nest")
                continue
            }
            #expect(id == A)
            #expect(under == B, "y=\(y): the parent, not the step")
        }
        let m = DropResolver.resolve(rows: rows, pointerY: 172, subject: .subtask(B1, parent: B), order: order, holdSeconds: 0.7, isManualSort: true)!
        #expect(DropPlanner.command(for: m, subject: .subtask(B1, parent: B)) == .moveSubtask(B1, under: C, before: nil))
        let i = DropResolver.resolve(rows: rows, pointerY: 2, subject: .task(C), order: order, holdSeconds: 0, isManualSort: true)!
        #expect(DropPlanner.command(for: i, subject: .task(C)) == .moveTask(C, before: A))
    }

    // MARK: positive controls

    @Test("positive control: the table notices a resolver that ignores the hold")
    func controlIgnoringHold() {
        let broken = resolveTable.filter { !check($0, hold: 0.7).isEmpty }
        #expect(!broken.isEmpty)
        #expect(broken.contains { $0.name == "C onto A centre, no hold yet" })
    }

    @Test("positive control: the table notices a resolver that ignores the sort mode")
    func controlIgnoringSortMode() {
        let broken = resolveTable.filter { !check($0, manual: true).isEmpty }
        #expect(broken.contains { $0.name == "sorted: C onto A top edge" })
    }

    @Test("positive control: the table notices a resolver that never holds")
    func controlNeverHolds() {
        let broken = resolveTable.filter { !check($0, hold: 0).isEmpty }
        #expect(broken.contains { $0.name == "C onto A centre, held" })
        #expect(broken.contains { $0.name == "external onto B centre, held" })
    }
}
