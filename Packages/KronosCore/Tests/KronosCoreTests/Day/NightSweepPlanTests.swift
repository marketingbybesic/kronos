// What the night sweep does to the plan and to carry. Hand-written expectations: the day numbers
// in each test are counted on a calendar, not derived from the code under test.

import Testing
import Foundation
@testable import KronosCore

@MainActor
struct NightSweepPlanTests {
    static let start = Day.parseISO("2026-10-10") ?? 0

    @MainActor private struct World {
        let store: TaskStore
        let clock: FixtureClock
        let defaults: FixtureKeyValueStore
        let sweep: NightSweep
        /// Moves the clock one calendar day and sweeps.
        func nextDay(_ n: Int = 1) { clock.advance(days: n); sweep.runIfNeeded() }
    }

    private func makeWorld() throws -> World {
        let store = try TaskStore(inMemory: true)
        let clock = FixtureClock(day: Self.start)
        let defaults = FixtureKeyValueStore()
        let sweep = NightSweep(store: store, clock: clock, defaults: defaults)
        sweep.runIfNeeded()   // the first sweep on the start day itself
        return World(store: store, clock: clock, defaults: defaults, sweep: sweep)
    }

    @Test func carryGrowsByOnePerLateDayAndDreadSetsAtTwo() throws {
        let w = try makeWorld()
        let t = w.store.create(title: "late", status: .todo, dueDay: Self.start - 1)
        // Day 0 sweep already ran; the first sweep that sees it late is tomorrow? No: it is
        // 1 day late today but the sweep for today has run, so tomorrow (2 days late) is the first.
        w.nextDay()   // start+1: due start-1 is 2 days late, one sweep day passed -> carry 1
        #expect(t.carryCount == 1)
        #expect(t.dread == false)
        w.nextDay()   // start+2 -> carry 2
        #expect(t.carryCount == 2)
        #expect(t.dread == true)
        w.nextDay()   // start+3 -> carry 3
        #expect(t.carryCount == 3)
        #expect(t.dueDay == Self.start - 1, "the deadline is never written")
        #expect(t.originalDueDay == Self.start - 1)
    }

    @Test func daysTheAppWasClosedAreCountedUpToTheDaysTheTaskIsLate() throws {
        let w = try makeWorld()
        let veryLate = w.store.create(title: "very late", status: .todo, dueDay: Self.start - 10)
        let barelyLate = w.store.create(title: "barely late", status: .todo, dueDay: Self.start + 2)
        w.nextDay(4)  // sweep runs once, 4 days after the last: start+4
        #expect(veryLate.carryCount == 4, "min(4 days since the last sweep, 14 days late)")
        #expect(barelyLate.carryCount == 2, "min(4 days since the last sweep, 2 days late)")
        #expect(veryLate.dread == true && barelyLate.dread == true)
    }

    @Test func theVeryFirstSweepCountsOneDay() throws {
        let store = try TaskStore(inMemory: true)
        let clock = FixtureClock(day: Self.start)
        let t = store.create(title: "late", status: .todo, dueDay: Self.start - 6)
        NightSweep(store: store, clock: clock, defaults: FixtureKeyValueStore()).runIfNeeded()
        #expect(t.carryCount == 1)
    }

    @Test func aPlannedDayInThePastRollsToTodayWithoutCarry() throws {
        let w = try makeWorld()
        let t = w.store.create(title: "planned", status: .todo, dueDay: Self.start - 3)
        w.store.updateNoUndo(t.id) { $0.plannedDay = Self.start }
        w.nextDay(2)
        #expect(t.plannedDay == Self.start + 2)
        #expect(t.carryCount == 0)
        #expect(t.dread == false)
        #expect(t.dueDay == Self.start - 3, "the deadline stays")
    }

    @Test func plannedTodayAndFutureAreLeftAlone() throws {
        let w = try makeWorld()
        let future = w.store.create(title: "later", status: .todo, dueDay: nil)
        w.store.updateNoUndo(future.id) { $0.plannedDay = Self.start + 5 }
        let today = w.store.create(title: "today", status: .todo, dueDay: nil)
        w.store.updateNoUndo(today.id) { $0.plannedDay = Self.start + 1 }
        w.nextDay()
        #expect(future.plannedDay == Self.start + 5)
        #expect(today.plannedDay == Self.start + 1)
    }

    @Test func onlyActiveOpenTasksAreCountedAndClosedOnesAreSkipped() throws {
        let w = try makeWorld()
        let waiting = w.store.create(title: "waiting", status: .todo, dueDay: Self.start - 2)
        w.store.updateNoUndo(waiting.id) { $0.status = .waiting }
        let done = w.store.create(title: "done", status: .todo, dueDay: Self.start - 2)
        w.store.updateNoUndo(done.id) { $0.status = .done }
        let someday = w.store.create(title: "someday", status: .todo, dueDay: Self.start - 2)
        w.store.updateNoUndo(someday.id) { $0.status = .someday }
        let live = w.store.create(title: "live", status: .inProgress, dueDay: Self.start - 2)
        w.nextDay()
        #expect(waiting.carryCount == 0 && done.carryCount == 0 && someday.carryCount == 0)
        #expect(live.carryCount == 1)
    }

    @Test func aSubtaskThatIsLateCarriesItsParent() throws {
        let w = try makeWorld()
        let parent = w.store.create(title: "parent", status: .todo, dueDay: Self.start + 9)
        _ = w.store.addChild(to: parent.id, title: "step", dueDay: Self.start - 1, priority: .none)
        w.nextDay()
        #expect(w.store.task(parent.id)?.carryCount == 1)
        #expect(w.store.task(parent.id)?.dueDay == Self.start + 9)
    }

    @Test func aPersonWhoClearsDreadIsNotArguedWithOnTheNextNight() throws {
        let w = try makeWorld()
        let t = w.store.create(title: "late", status: .todo, dueDay: Self.start - 5)
        w.nextDay(); w.nextDay()
        #expect(t.dread == true)
        w.store.setDread(t.id, false)
        w.nextDay()
        #expect(t.carryCount == 3)
        #expect(t.dread == false, "the flag is set on the night carry reaches 2, not on every night after")
    }

    @Test func theSweepPushesNoUndoStepAndRunsOncePerDay() throws {
        let w = try makeWorld()
        let t = w.store.create(title: "late", status: .todo, dueDay: Self.start - 1)
        let depth = w.store.undoDepth
        w.nextDay()
        #expect(w.store.undoDepth == depth)
        let carry = t.carryCount
        w.sweep.runIfNeeded()
        #expect(t.carryCount == carry)
    }

    @Test func aTaskDoneBeforeTheSweepIsNotCarried() throws {
        let w = try makeWorld()
        let t = w.store.create(title: "late", status: .todo, dueDay: Self.start - 1)
        w.store.complete(t.id)
        w.nextDay()
        #expect(t.carryCount == 0)
    }
}
