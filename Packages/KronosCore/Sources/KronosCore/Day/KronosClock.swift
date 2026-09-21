// Injected clock. `Date()` and `Calendar.current` are
// read exactly once each in shipped code, inside `SystemClock` — everything
// else here takes a `KronosClock` so a test can move time by hand
// instead of racing the wall clock.

import Foundation

/// The current instant, calendar and time zone, as one injectable unit.
///
/// `calendar` and `timeZone` travel together deliberately: a timezone change
/// (T3, data-model §8.2) must be observable by swapping both at once, the way
/// `NSSystemTimeZoneDidChange` really changes `Calendar.current.timeZone`.
public protocol KronosClock: Sendable {
    var now: Date { get }
    var calendar: Calendar { get }
    var timeZone: TimeZone { get }
}

/// The real clock. Used exactly once, at the app's composition root.
public struct SystemClock: KronosClock {
    public init() {}
    public var now: Date { Date() }
    public var calendar: Calendar { .current }
    public var timeZone: TimeZone { .current }
}

/// A hand-advanced clock for tests. Reference type so a coordinator holding
/// it and a test advancing it see the same mutable state.
public final class FixtureClock: KronosClock, @unchecked Sendable {
    public var now: Date
    public var calendar: Calendar

    public init(now: Date = Date(), timeZone: TimeZone = TimeZone(identifier: "Europe/Zagreb")!) {
        self.now = now
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        self.calendar = cal
    }

    public var timeZone: TimeZone { calendar.timeZone }

    /// Move to a given local calendar day, keeping the same time-of-day.
    public convenience init(day: Int, timeOfDay: TimeInterval = 9 * 3600,
                             timeZone: TimeZone = TimeZone(identifier: "Europe/Zagreb")!) {
        self.init(now: Date(timeIntervalSince1970: 0), timeZone: timeZone)
        self.now = Day.date(day, calendar: calendar).addingTimeInterval(timeOfDay)
    }

    /// Advance by calendar days (never `+86400`: a day can be 23, 24 or 25
    /// hours long across a DST boundary).
    public func advance(days: Int) {
        now = calendar.date(byAdding: .day, value: days, to: now) ?? now
    }

    public func advance(hours: Int) {
        now = now.addingTimeInterval(TimeInterval(hours) * 3600)
    }

    /// Simulate a system timezone change: same instant, new wall-clock day.
    public func travel(to identifier: String) {
        guard let tz = TimeZone(identifier: identifier) else { return }
        calendar.timeZone = tz
    }
}

public extension KronosClock {
    /// Today as a `Day` number (days since 1970-01-01), in this clock's
    /// calendar. Delegates to the one `Day` epoch-math implementation in
    /// Contracts.swift — never reimplemented here.
    func today() -> Int { Day.from(now, calendar: calendar) }

    /// Local midnight strictly after `now` — the coordinator's next wake-up
    /// point. Computed via the calendar, never `now + 86400`.
    func nextMidnight() -> Date {
        let startOfToday = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now.addingTimeInterval(86_400)
    }
}
