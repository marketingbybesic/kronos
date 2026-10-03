// Which tasks belong to Today and to Next 7 days once a task can carry a planned day.
// Hand-written truth table: the schedule day is the planned day when there is one, else the
// effective due day. Every expectation below was worked out by hand from that sentence.

import Testing
import Foundation
@testable import KronosCore

@MainActor
struct TodayScopeTests {
    static let today = Day.parseISO("2026-10-10") ?? 0

    private struct Row {
        let name: String
        let status: KStatus
        let planned: Int?     // offset from today
        let due: Int?         // offset from today
        let inToday: Bool
        let inNext7: Bool
    }

    private static let table: [Row] = [
        Row(name: "overdue, unplanned",            status: .todo,       planned: nil, due: -3, inToday: true,  inNext7: false),
        Row(name: "due today, unplanned",          status: .todo,       planned: nil, due: 0,  inToday: true,  inNext7: true),
        Row(name: "due in 5 days, unplanned",      status: .todo,       planned: nil, due: 5,  inToday: false, inNext7: true),
        Row(name: "due in 8 days, unplanned",      status: .todo,       planned: nil, due: 8,  inToday: false, inNext7: false),
        Row(name: "no dates at all",               status: .todo,       planned: nil, due: nil, inToday: false, inNext7: false),
        Row(name: "planned today, no deadline",    status: .todo,       planned: 0,   due: nil, inToday: true,  inNext7: true),
        Row(name: "planned 2 days ago, no deadline", status: .todo,     planned: -2,  due: nil, inToday: true,  inNext7: false),
        Row(name: "overdue but planned tomorrow",  status: .todo,       planned: 1,   due: -5, inToday: false, inNext7: true),
        Row(name: "due today but planned tomorrow", status: .inProgress, planned: 1,  due: 0,  inToday: false, inNext7: true),
        Row(name: "planned today, due in 20 days", status: .todo,       planned: 0,   due: 20, inToday: true,  inNext7: true),
        Row(name: "planned in 8 days, due today",  status: .todo,       planned: 8,   due: 0,  inToday: false, inNext7: false),
        Row(name: "planned today but done",        status: .done,       planned: 0,   due: nil, inToday: false, inNext7: false),
        Row(name: "planned today but canceled",    status: .canceled,   planned: 0,   due: nil, inToday: false, inNext7: false),
        Row(name: "waiting, planned in 3 days",    status: .waiting,    planned: 3,   due: nil, inToday: false, inNext7: true),
        Row(name: "waiting, planned today",        status: .waiting,    planned: 0,   due: nil, inToday: true,  inNext7: true),
    ]

    private func make(_ row: Row, in store: TaskStore) -> KTask {
        let t = store.create(title: row.name, status: .todo, dueDay: row.due.map { Self.today + $0 })
        store.updateNoUndo(t.id) { k in
            k.status = row.status
            k.plannedDay = row.planned.map { Self.today + $0 }
        }
        return store.taskIncludingDeleted(t.id)!
    }

    @Test func dueScopeMatchesTheHandTable() throws {
        let store = try TaskStore(inMemory: true)
        for row in Self.table {
            let t = make(row, in: store)
            #expect(DueScope.isToday(t, today: Self.today) == row.inToday, "Today: \(row.name)")
            #expect(DueScope.isNext7(t, today: Self.today) == row.inNext7, "Next 7: \(row.name)")
        }
    }

    /// The list a person sees (`KFilter`, used by the sidebar scope's base filter) must agree with
    /// the membership rule row by row, or a badge says 4 and the list shows 3.
    @Test func filterWindowsAgreeWithDueScope() throws {
        let store = try TaskStore(inMemory: true)
        var today = KFilter.empty
        today.due = .today
        var next7 = KFilter.empty
        next7.due = .next7
        for row in Self.table where KStatus.open.contains(row.status) {
            let t = make(row, in: store)
            #expect(today.matches(t, today: Self.today) == row.inToday, "filter Today: \(row.name)")
            #expect(next7.matches(t, today: Self.today) == row.inNext7, "filter Next 7: \(row.name)")
        }
    }

    @Test func overdueWindowStillReadsTheDeadlineNotThePlan() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.create(title: "late but planned", status: .todo, dueDay: Self.today - 4)
        store.updateNoUndo(t.id) { $0.plannedDay = Self.today + 1 }
        var overdue = KFilter.empty
        overdue.due = .overdue
        #expect(overdue.matches(store.task(t.id)!, today: Self.today))
    }

    @Test func aSubtaskDueTodayStillBringsItsParentIntoToday() throws {
        let store = try TaskStore(inMemory: true)
        let parent = store.create(title: "parent", status: .todo, dueDay: Self.today + 9)
        _ = store.addChild(to: parent.id, title: "step", dueDay: Self.today, priority: .none)
        let p = try #require(store.task(parent.id))
        #expect(DueScope.isToday(p, today: Self.today))
        store.updateNoUndo(parent.id) { $0.plannedDay = Self.today + 2 }
        #expect(!DueScope.isToday(store.task(parent.id)!, today: Self.today), "a planned day wins over a step's date")
    }
}
