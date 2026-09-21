// Detects a local-calendar day change from
// several unreliable signals and turns it into exactly one
// `.kronosDayDidChange` post per real day change, guarded by a stored
// `lastHandledDay` so ten triggers in the same second do one thing.
//
// A rollover job once MUTATED due dates and a
// stored carry counter let an offline device resurrect a completed task.
// Nothing here writes a due date — see `KTask.carryDays(today:)` in
// Contracts.swift, which this file reuses rather than duplicates. This file
// only decides WHEN the day changed; carrying is computed at render.

import Foundation

/// Schedules one wake-up at a future date and can be canceled. Injected so
/// tests advance the fixture clock and call `fire()` by hand instead of
/// waiting on a real timer.
@MainActor
public protocol DayChangeScheduling: AnyObject {
    func schedule(at date: Date, _ fire: @escaping () -> Void)
    func cancel()
}

/// Production scheduler: one repeating check backed by `Timer`, tolerant of
/// the run loop coalescing fires, because `checkForDayChange()` is idempotent
/// regardless of how many times it runs.
@MainActor
public final class TimerDayChangeScheduler: DayChangeScheduling {
    private var timer: Timer?
    public init() {}

    public func schedule(at date: Date, _ fire: @escaping () -> Void) {
        cancel()
        let interval = max(1, date.timeIntervalSinceNow)
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in fire() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func cancel() {
        timer?.invalidate()
        timer = nil
    }
}

/// Detects the local-calendar day change and republishes it once.
///
/// Re-evaluates on: its own midnight timer, wake from sleep, a system
/// timezone change, `NSCalendarDayChanged`, and app activation — those last
/// four are wired by `DayChangeObservers` (AppKit adapter) so this type stays
/// pure Foundation and fully testable without a running app.
@MainActor
public final class DayChangeCoordinator {
    public static let lastHandledDayKey = "kronos.dayChange.lastHandledDay"

    private let clock: KronosClock
    private let scheduler: DayChangeScheduling
    private let defaults: DayKeyValueStore
    private let center: NotificationCenter

    public init(clock: KronosClock,
                scheduler: DayChangeScheduling,
                defaults: DayKeyValueStore,
                center: NotificationCenter = .default) {
        self.clock = clock
        self.scheduler = scheduler
        self.defaults = defaults
        self.center = center
    }

    /// The last day this coordinator successfully handled, or the clock's
    /// current day if it has never run (so a fresh install does not fire a
    /// spurious change on its very first check).
    private var lastHandledDay: Int {
        get {
            let stored = defaults.integer(forKey: Self.lastHandledDayKey)
            return stored == 0 ? clock.today() : stored
        }
        set { defaults.setInteger(newValue, forKey: Self.lastHandledDayKey) }
    }

    /// Call once at launch, after the container is ready (T1). Records
    /// today without posting — there is no "previous day" to compare to yet.
    public func start() {
        defaults.setInteger(clock.today(), forKey: Self.lastHandledDayKey)
        scheduleNextMidnight()
    }

    /// Re-evaluate now. Idempotent: calling this ten times in the same
    /// second, or after sleeping across two midnights, posts
    /// `.kronosDayDidChange` at most once, carrying both the day that just
    /// ended and the day that started.
    ///
    /// The comparison is `!=`, not `<` (data-model.md §8.3): a backwards
    /// clock move or a westward timezone crossing must still count as a
    /// change, not be ignored because "today" went down.
    public func checkForDayChange() {
        let today = clock.today()
        let previous = lastHandledDay
        guard previous != today else { return }
        lastHandledDay = today
        center.post(name: .kronosDayDidChange, object: self,
                    userInfo: ["previousDay": previous, "newDay": today])
        scheduleNextMidnight()
    }

    /// Local midnight, computed from the calendar every time — never
    /// `+86400`, which is wrong on both ends of DST (2026-10-25 is a 25-hour
    /// day in Zagreb, 2026-03-29 is 23).
    private func scheduleNextMidnight() {
        scheduler.schedule(at: clock.nextMidnight()) { [weak self] in
            self?.checkForDayChange()
        }
    }
}
