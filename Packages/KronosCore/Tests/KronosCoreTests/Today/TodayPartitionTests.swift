// The split of Today into current rows and the Earlier section.

import Testing
import Foundation
@testable import KronosCore

@MainActor
struct TodayPartitionTests {
    static let today = Day.parseISO("2026-10-10") ?? 0

    private struct Row {
        let name: String
        let due: Int?
        let planned: Int?
        let carry: Int
        let earlier: Bool
    }

    // Hand table. Earlier = carried at least once, or scheduled (planned, else due) before today.
    private static let table: [Row] = [
        Row(name: "due today",                         due: 0,   planned: nil, carry: 0, earlier: false),
        Row(name: "due yesterday",                     due: -1,  planned: nil, carry: 0, earlier: true),
        Row(name: "due yesterday, carried once",       due: -1,  planned: nil, carry: 1, earlier: true),
        Row(name: "due today but carry 1 left over",   due: 0,   planned: nil, carry: 1, earlier: true),
        Row(name: "planned today, old deadline",       due: -9,  planned: 0,   carry: 0, earlier: false),
        Row(name: "planned yesterday",                 due: nil, planned: -1,  carry: 0, earlier: true),
        Row(name: "planned today, no deadline",        due: nil, planned: 0,   carry: 0, earlier: false),
        Row(name: "dated nowhere, never carried",      due: nil, planned: nil, carry: 0, earlier: false),
    ]

    @Test func splitFollowsTheHandTableAndKeepsOrder() throws {
        let store = try TaskStore(inMemory: true)
        var rows: [KTask] = []
        for r in Self.table {
            let t = store.create(title: r.name, status: .todo, dueDay: r.due.map { Self.today + $0 })
            store.updateNoUndo(t.id) { k in
                k.plannedDay = r.planned.map { Self.today + $0 }
                k.carryCount = r.carry
            }
            rows.append(store.task(t.id)!)
        }
        let (current, earlier) = TodayPartition.split(rows: rows, today: Self.today)
        #expect(current.map(\.title) == Self.table.filter { !$0.earlier }.map(\.name))
        #expect(earlier.map(\.title) == Self.table.filter { $0.earlier }.map(\.name))
        #expect(current.count + earlier.count == Self.table.count)
    }

    @Test func emptyInputGivesTwoEmptyLists() {
        let (current, earlier) = TodayPartition.split(rows: [], today: Self.today)
        #expect(current.isEmpty && earlier.isEmpty)
    }
}
