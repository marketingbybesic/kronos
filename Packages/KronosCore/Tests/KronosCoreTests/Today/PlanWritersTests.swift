// The writers of `plannedDay`: plan, snooze, Waiting, the T and H keys and Fresh start.
// None of them writes the deadline; each is one undo step.

import Testing
import Foundation
@testable import KronosCore

@MainActor
struct PlanWritersTests {
    static let today = Day.parseISO("2026-10-10") ?? 0

    private func makeStore() throws -> TaskStore { try TaskStore(inMemory: true) }

    // MARK: plan and snooze

    @Test func planWritesOnlyThePlannedDayAndResetsCarry() throws {
        let store = try makeStore()
        let t = store.create(title: "a", status: .todo, dueDay: Self.today - 2)
        store.updateNoUndo(t.id) { $0.carryCount = 3 }
        store.plan(t.id, day: Self.today + 4)
        let got = try #require(store.task(t.id))
        #expect(got.plannedDay == Self.today + 4)
        #expect(got.carryCount == 0)
        #expect(got.dueDay == Self.today - 2, "the deadline is never written")
    }

    @Test func clearingThePlanKeepsCarry() throws {
        let store = try makeStore()
        let t = store.create(title: "a", status: .todo, dueDay: nil)
        store.updateNoUndo(t.id) { $0.plannedDay = Self.today; $0.carryCount = 2 }
        store.plan(t.id, day: nil)
        #expect(store.task(t.id)?.plannedDay == nil)
        #expect(store.task(t.id)?.carryCount == 2)
    }

    @Test func snoozeLeavesAnUndatedTaskUndatedAndPlansTomorrow() throws {
        let store = try makeStore()
        let t = store.create(title: "a", status: .todo, dueDay: nil)
        store.snooze(t.id, today: Self.today)
        let got = try #require(store.task(t.id))
        #expect(got.plannedDay == Self.today + 1)
        #expect(got.dueDay == nil)
        #expect(got.status == .todo, "no deadline was written, so the automatic rule never ran")
    }

    @Test func snoozeOnAnOverdueTaskTakesItOutOfTodayWithoutMovingItsDeadline() throws {
        let store = try makeStore()
        let t = store.create(title: "late", status: .todo, dueDay: Self.today - 5)
        #expect(DueScope.isToday(try #require(store.task(t.id)), today: Self.today))
        store.snooze(t.id, today: Self.today)
        let got = try #require(store.task(t.id))
        #expect(got.dueDay == Self.today - 5)
        #expect(!DueScope.isToday(got, today: Self.today))
        #expect(DueScope.isToday(got, today: Self.today + 1))
    }

    @Test func planAndUndoRedoAlternate() throws {
        let store = try makeStore()
        let t = store.create(title: "a", status: .todo, dueDay: nil)
        let base = store.undoDepth
        store.plan(t.id, day: Self.today + 2)
        #expect(store.undoDepth == base + 1)
        store.undo()
        #expect(store.task(t.id)?.plannedDay == nil)
        store.redo()
        #expect(store.task(t.id)?.plannedDay == Self.today + 2)
    }

    @Test func aPlanThatChangesNothingPushesNoStep() throws {
        let store = try makeStore()
        let t = store.create(title: "a", status: .todo, dueDay: nil)
        store.plan(t.id, day: Self.today)
        let depth = store.undoDepth
        store.plan(t.id, day: Self.today)
        #expect(store.undoDepth == depth)
        store.plan(UUID(), day: Self.today)
        #expect(store.undoDepth == depth, "a missing task is a no-op")
        store.plan([], day: Self.today)
        #expect(store.undoDepth == depth)
    }

    // MARK: keys

    @Test func tAndHPlanSeveralTasksAsOneUndoStep() throws {
        let store = try makeStore()
        let a = store.create(title: "a", status: .todo, dueDay: nil)
        let b = store.create(title: "b", status: .todo, dueDay: Self.today - 1)
        let base = store.undoDepth
        store.planForTomorrow([a.id, b.id], today: Self.today)
        #expect(store.undoDepth == base + 1)
        #expect(store.task(a.id)?.plannedDay == Self.today + 1)
        #expect(store.task(b.id)?.plannedDay == Self.today + 1)
        #expect(store.task(b.id)?.dueDay == Self.today - 1)
        store.planForToday([a.id], today: Self.today)
        #expect(store.task(a.id)?.plannedDay == Self.today)
        store.undo()
        store.undo()
        #expect(store.task(a.id)?.plannedDay == nil && store.task(b.id)?.plannedDay == nil)
    }

    // MARK: Waiting

    @Test func waitingPlansThreeDaysAheadInOneUndoStep() throws {
        let store = try makeStore()
        let t = store.create(title: "chase", status: .todo, dueDay: nil)
        let base = store.undoDepth
        store.setWaiting(t.id, true, today: Self.today)
        let got = try #require(store.task(t.id))
        #expect(got.status == .waiting)
        #expect(got.plannedDay == Self.today + 3)
        #expect(store.undoDepth == base + 1, "status and plan are one step")
        store.undo()
        #expect(store.task(t.id)?.status == .todo)
        #expect(store.task(t.id)?.plannedDay == nil)
        store.redo()
        #expect(store.task(t.id)?.status == .waiting)
        #expect(store.task(t.id)?.plannedDay == Self.today + 3)
    }

    @Test func waitingComesBackToTodayOnItsDay() throws {
        let store = try makeStore()
        let t = store.create(title: "chase", status: .todo, dueDay: nil)
        store.setWaiting(t.id, true, today: Self.today)
        let got = try #require(store.task(t.id))
        #expect(!DueScope.isToday(got, today: Self.today + 2))
        #expect(DueScope.isToday(got, today: Self.today + 3))
    }

    @Test func releasingWaitingDropsAFuturePlanButKeepsAPastOne() throws {
        let store = try makeStore()
        let a = store.create(title: "a", status: .todo, dueDay: Self.today + 1)
        store.setWaiting(a.id, true, today: Self.today)
        store.setWaiting(a.id, false, today: Self.today + 1)
        #expect(store.task(a.id)?.plannedDay == nil, "the 3-day deferral belonged to the waiting")
        #expect(store.task(a.id)?.status == .todo)

        let b = store.create(title: "b", status: .todo, dueDay: Self.today + 1)
        store.setWaiting(b.id, true, today: Self.today)
        store.setWaiting(b.id, false, today: Self.today + 5)
        #expect(store.task(b.id)?.plannedDay == Self.today + 3, "a plan already reached is left alone")
    }

    @Test func settingWaitingTwiceChangesNothingTheSecondTime() throws {
        let store = try makeStore()
        let t = store.create(title: "a", status: .todo, dueDay: nil)
        store.setWaiting(t.id, true, today: Self.today)
        let depth = store.undoDepth
        store.setWaiting(t.id, true, today: Self.today + 1)
        #expect(store.undoDepth == depth)
        #expect(store.task(t.id)?.plannedDay == Self.today + 3)
    }

    // MARK: Fresh start

    private func makeEarlier(_ store: TaskStore, count: Int) -> [UUID] {
        (0..<count).map { i in
            let t = store.create(title: "late \(i)", status: .todo, dueDay: Self.today - 4)
            store.updateNoUndo(t.id) { $0.carryCount = 4 }
            return t.id
        }
    }

    @Test func freshStartTomorrowMovesFiveTasksOutOfTodayAndOneUndoRestoresThem() throws {
        let store = try makeStore()
        let ids = makeEarlier(store, count: 5)
        func snapshot() -> [String] {
            ids.map { id in
                let t = store.task(id)!
                return "\(String(describing: t.plannedDay))|\(t.carryCount)|\(String(describing: t.dueDay))|\(t.statusRaw)"
            }
        }
        let before = snapshot()
        let rowsBefore = store.allTasks().filter { DueScope.isToday($0, today: Self.today) }
        #expect(TodayPartition.split(rows: rowsBefore, today: Self.today).earlier.count == 5)

        let depth = store.undoDepth
        store.freshStart(ids: ids, to: .tomorrow, today: Self.today)
        #expect(store.undoDepth == depth + 1, "one undo step for five tasks")
        for id in ids {
            let t = try #require(store.task(id))
            #expect(t.plannedDay == Self.today + 1)
            #expect(t.carryCount == 0)
            #expect(t.dueDay == Self.today - 4)
        }
        #expect(store.allTasks().filter { DueScope.isToday($0, today: Self.today) }.isEmpty)

        store.undo()
        #expect(snapshot() == before, "one Cmd-Z restores every field of every task")
        store.redo()
        #expect(store.task(ids[0])?.plannedDay == Self.today + 1)
    }

    @Test func freshStartTodayKeepsTasksInTodayButNotInEarlier() throws {
        let store = try makeStore()
        let ids = makeEarlier(store, count: 3)
        store.freshStart(ids: ids, to: .today, today: Self.today)
        let rows = store.allTasks().filter { DueScope.isToday($0, today: Self.today) }
        #expect(rows.count == 3)
        let parts = TodayPartition.split(rows: rows, today: Self.today)
        #expect(parts.earlier.isEmpty)
        #expect(parts.current.count == 3)
    }

    @Test func freshStartSomedayClearsPlanDeadlineAndCarryInOneStep() throws {
        let store = try makeStore()
        let ids = makeEarlier(store, count: 2)
        let first = try #require(store.task(ids[0]))
        let original = first.originalDueDay
        let depth = store.undoDepth
        store.freshStart(ids: ids, to: .someday, today: Self.today)
        #expect(store.undoDepth == depth + 1)
        for id in ids {
            let t = try #require(store.task(id))
            #expect(t.status == .someday && t.dueDay == nil && t.plannedDay == nil && t.carryCount == 0)
            #expect(!DueScope.isToday(t, today: Self.today))
        }
        #expect(store.task(ids[0])?.originalDueDay == original && original != nil)
        store.undo()
        let back = try #require(store.task(ids[0]))
        #expect(back.status == .todo && back.dueDay == Self.today - 4 && back.carryCount == 4)
    }

    @Test func freshStartSkipsClosedAndMissingTasksAndPushesNothingWhenNoneQualify() throws {
        let store = try makeStore()
        let done = store.create(title: "done", status: .todo, dueDay: Self.today - 1)
        store.complete(done.id)
        let depth = store.undoDepth
        store.freshStart(ids: [done.id, UUID()], to: .tomorrow, today: Self.today)
        #expect(store.undoDepth == depth)
        #expect(store.task(done.id)?.plannedDay == nil)
        store.freshStart(ids: [], to: .today, today: Self.today)
        #expect(store.undoDepth == depth)
    }
}
