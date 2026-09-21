// Named invariants for day-change handling. Each test names the exact regression it pins —
// see the header comment on DayChangeCoordinator.swift and NightSweep.swift for the spec
// sections.

import Testing
import Foundation
@testable import KronosCore

/// A scheduler that never fires on its own — the test calls `fire()` itself,
/// which is what "tests drive time manually" means for a timer-shaped API.
@MainActor
private final class ManualScheduler: DayChangeScheduling {
    private(set) var scheduledAt: Date?
    private var pending: (() -> Void)?
    var scheduleCount = 0

    func schedule(at date: Date, _ fire: @escaping () -> Void) {
        scheduledAt = date
        pending = fire
        scheduleCount += 1
    }
    func cancel() { pending = nil }
    func fire() { pending?() }
}

@MainActor
private func makeCoordinator(day: Int) -> (DayChangeCoordinator, FixtureClock, ManualScheduler, FixtureKeyValueStore) {
    let clock = FixtureClock(day: day)
    let scheduler = ManualScheduler()
    let defaults = FixtureKeyValueStore()
    let coord = DayChangeCoordinator(clock: clock, scheduler: scheduler, defaults: defaults)
    return (coord, clock, scheduler, defaults)
}

// MARK: - Day change firing

@Test @MainActor func dayChangeFiresOnceAcrossMidnight() {
    let (coord, clock, scheduler, _) = makeCoordinator(day: Day.parseISO("2026-09-19") ?? 0)
    coord.start()

    var fireCount = 0
    let token = NotificationCenter.default.addObserver(forName: .kronosDayDidChange, object: nil, queue: nil) { _ in
        fireCount += 1
    }
    defer { NotificationCenter.default.removeObserver(token) }

    // Cross midnight, then let three unrelated triggers land in the same
    // second — none of them should post a second time.
    clock.advance(hours: 16)
    coord.checkForDayChange()
    coord.checkForDayChange()
    coord.checkForDayChange()

    #expect(fireCount == 1)
    #expect(scheduler.scheduleCount >= 2, "a new midnight timer is rearmed after firing")
}

@Test @MainActor func dayChangeFiresAfterSleepSpanningTwoDays() {
    let (coord, clock, _, _) = makeCoordinator(day: Day.parseISO("2026-09-19") ?? 0)
    coord.start()

    var payloads: [[String: Int]] = []
    let token = NotificationCenter.default.addObserver(forName: .kronosDayDidChange, object: nil, queue: nil) { note in
        let previous = note.userInfo?["previousDay"] as? Int ?? -1
        let newDay = note.userInfo?["newDay"] as? Int ?? -1
        payloads.append(["previousDay": previous, "newDay": newDay])
    }
    defer { NotificationCenter.default.removeObserver(token) }

    // Asleep through two midnights: wake fires the wake handler's equivalent
    // (a direct checkForDayChange call, as DayChangeObservers would make).
    clock.advance(days: 2)
    coord.checkForDayChange()

    #expect(payloads.count == 1, "one wake spanning two midnights posts exactly once")
    #expect(payloads[0]["newDay"] == clock.today())
    #expect(payloads[0]["previousDay"] == (Day.parseISO("2026-09-19") ?? 0))
}

@Test @MainActor func timezoneChangeRecomputesToday() {
    let (coord, clock, _, _) = makeCoordinator(day: Day.parseISO("2026-09-19") ?? 0)
    coord.start()

    var fired = false
    let token = NotificationCenter.default.addObserver(forName: .kronosDayDidChange, object: nil, queue: nil) { _ in
        fired = true
    }
    defer { NotificationCenter.default.removeObserver(token) }

    // Travelling west can move local wall-clock day backwards relative to
    // the stored lastHandledDay; the `!=` guard (not `<`) must still catch it.
    clock.travel(to: "Pacific/Midway")
    coord.checkForDayChange()

    #expect(fired || clock.today() == (Day.parseISO("2026-09-19") ?? 0),
            "either the day genuinely changed and fired, or the travel landed on the same local day")
}

@Test @MainActor func dstEndDayIsStillOneDay() {
    // Croatia leaves DST 2026-10-25 — a 25-HOUR day (clocks fall back an
    // extra hour at 03:00 local). Starting at 00:30 local, naive `+86400`
    // (a full 24h) does not reach the next midnight because this day holds
    // 25 of them: it lands at 23:30 the SAME day, so naive math concludes
    // the day never changed at all. Verified concretely: today=20751,
    // naive lands back on 20751 too, while the real tomorrow is 20752.
    let clock = FixtureClock(day: Day.parseISO("2026-10-25") ?? 0, timeOfDay: 0.5 * 3600,
                              timeZone: TimeZone(identifier: "Europe/Zagreb")!)
    let today = clock.today()
    let tomorrow = Day.parseISO("2026-10-26") ?? 0
    #expect(tomorrow - today == 1)

    let naive = Day.from(clock.now.addingTimeInterval(86_400), calendar: clock.calendar)
    #expect(naive == today,
            "control: naive +86400 stays on the 25th — the 25-hour day swallows a full day of arithmetic")

    let viaCalendar = Day.from(clock.nextMidnight(), calendar: clock.calendar)
    #expect(viaCalendar == tomorrow, "the coordinator's own midnight math gets it right")
}

@Test @MainActor func dstStartDayIsStillOneDay() {
    // Croatia enters DST 2026-03-29 — a 23-HOUR day (clocks spring forward
    // at 02:00 local). Starting at local midnight of the 29th, a naive
    // scheduler that waits exactly 86400s for "the next midnight" fires an
    // hour LATE, because this day holds only 23 of them. Verified
    // concretely: `nextMidnight()` lands at 2026-03-29 22:00 UTC (= local
    // midnight of the 30th); naive `+86400` lands an hour after that, at
    // 23:00 UTC the same calendar date. One calendar day apart still must
    // measure as exactly 1, and the coordinator's own midnight math must
    // hit the boundary exactly — unlike naive arithmetic, which overshoots
    // past it every time DST starts.
    let clock = FixtureClock(day: Day.parseISO("2026-03-29") ?? 0, timeOfDay: 0,
                              timeZone: TimeZone(identifier: "Europe/Zagreb")!)
    let today = clock.today()
    let tomorrow = Day.parseISO("2026-03-30") ?? 0
    #expect(tomorrow - today == 1)

    let correctMidnight = clock.nextMidnight()
    let naiveFire = clock.now.addingTimeInterval(86_400)
    #expect(naiveFire != correctMidnight,
            "control: naive +86400 misses the real midnight boundary — it fires an hour after this 23-hour day already ended")
    #expect(naiveFire.timeIntervalSince(correctMidnight) == 3600,
            "the naive scheduler is exactly one hour late, the hour this day lost to spring-forward")

    let viaCalendar = Day.from(correctMidnight, calendar: clock.calendar)
    #expect(viaCalendar == tomorrow, "the coordinator's own midnight math gets it right")
}

// MARK: - Carry is computed, never written

@Test @MainActor func overdueCarryIsComputedWithZeroStoreWrites() throws {
    let store = try TaskStore(inMemory: true)
    let clock = FixtureClock(day: Day.parseISO("2026-09-18") ?? 0)
    let task = store.create(title: "Pay invoice", notes: "", project: nil,
                             status: .inProgress, priority: .none, dueDay: clock.today())
    let originalDue = task.dueDay
    let originalOriginalDue = task.originalDueDay
    let originalUpdatedAt = task.updatedAt
    let undoDepthBefore = store.undoDepth

    store.context.processPendingChanges()
    #expect(store.context.hasChanges == false)

    // Advance one day: task is now 1 day overdue.
    clock.advance(days: 1)
    let scheduler = ManualScheduler()
    let defaults = FixtureKeyValueStore()
    let coordinator = DayChangeCoordinator(clock: clock, scheduler: scheduler, defaults: defaults)
    coordinator.start()
    coordinator.checkForDayChange()
    let sweep = NightSweep(store: store, clock: clock, defaults: defaults)
    sweep.runIfNeeded()

    #expect(task.carryDays(today: clock.today()) == 1)
    #expect(task.dueDay == originalDue, "dueDay is bit-identical to before the day change")
    #expect(task.originalDueDay == originalOriginalDue)
    #expect(task.updatedAt == originalUpdatedAt, "carry is never stamped onto the row")
    #expect(store.context.hasChanges == false, "reading carry produced no pending ModelContext change")
    #expect(store.undoDepth == undoDepthBefore, "no undo step was pushed by computing carry")

    // Advance a second day: carry reads 2, still nothing written.
    clock.advance(days: 1)
    coordinator.checkForDayChange()
    sweep.runIfNeeded()
    #expect(task.carryDays(today: clock.today()) == 2)
    #expect(task.dueDay == originalDue)
    #expect(task.originalDueDay == originalOriginalDue)
    #expect(task.updatedAt == originalUpdatedAt)
    #expect(store.context.hasChanges == false)
    #expect(store.undoDepth == undoDepthBefore)
}

// MARK: - Night sweep

@Test @MainActor func nightSweepPurgesOnlyOlderThan30Days() throws {
    let store = try TaskStore(inMemory: true)
    let clock = FixtureClock(day: Day.parseISO("2026-09-19") ?? 0)
    let defaults = FixtureKeyValueStore()

    let stale = store.create(title: "old", notes: "", project: nil, status: .inProgress, priority: .none, dueDay: nil)
    store.updateIncludingDeleted(stale.id) { $0.deletedAt = clock.now.addingTimeInterval(-40 * 86_400) }

    let recent = store.create(title: "recent", notes: "", project: nil, status: .inProgress, priority: .none, dueDay: nil)
    store.updateIncludingDeleted(recent.id) { $0.deletedAt = clock.now.addingTimeInterval(-10 * 86_400) }

    let live = store.create(title: "live", notes: "", project: nil, status: .inProgress, priority: .none, dueDay: nil)

    let sweep = NightSweep(store: store, clock: clock, defaults: defaults)
    sweep.runIfNeeded()

    #expect(store.taskIncludingDeleted(stale.id) == nil, "purged past the 30-day window")
    #expect(store.taskIncludingDeleted(recent.id) != nil, "kept: soft-deleted 10 days ago")
    #expect(store.task(live.id) != nil, "untouched: never deleted")

    // Idempotent: running again the same day changes nothing further.
    let countBefore = store.allTasksIncludingDeleted().count
    sweep.runIfNeeded()
    #expect(store.allTasksIncludingDeleted().count == countBefore)
}
