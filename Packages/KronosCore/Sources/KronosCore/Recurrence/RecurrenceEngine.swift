// `TaskStore.complete(_:)` (TaskStore+Mutations.swift) calls `RecurrenceSpawner.spawnNext`
// right after marking the task done, inside the same `update` closure, so the spawn is part
// of the same undo step as the completion. It guards the call with `wasOpen` — the task's
// status before this call — reproducing data-model.md §6.2's "fires exactly once, entering
// .done only" rule without needing a public "old status" parameter on `complete`.
// `RecurrenceSpawner.spawnNext` itself is a no-op (returns nil) when the task has no
// `recurrenceRule`, so the call is safe on every non-recurring task.

import Foundation

/// Pure date math for recurrence: no store, no undo, no side effects. Every
/// day is a `dueDay`/`completedOn` Int (days since 1970-01-01, local
/// calendar) — never raw `Date` or 86400-second arithmetic, so a DST
/// transition cannot shift a result by an hour into the wrong calendar day.
public enum RecurrenceEngine {

    /// The next `dueDay` for `rule`, given the instance's current `dueDay`
    /// and the day it was actually completed (`completedOn`).
    ///
    /// Fixed-schedule rules (`daily`/`weekly`/`monthly`/`yearly`) anchor on
    /// `max(dueDay, completedOn)` when `rule.anchor == .fromDueDay` (data-model
    /// §6.2: collapses missed occurrences so a late completion never spawns an
    /// already-overdue instance), or on `completedOn` alone when
    /// `rule.anchor == .fromCompletionDay`. `everyNDays` always counts from
    /// `completedOn`, per its definition.
    ///
    /// The result is always strictly greater than both `dueDay` and
    /// `completedOn` for a `.fromDueDay` rule, and strictly greater than
    /// `completedOn` for a `.fromCompletionDay` rule or `everyNDays` — a task
    /// completed today never reappears due today or earlier.
    public static func nextDueDay(after dueDay: Int,
                                   rule: RecurrenceRule,
                                   completedOn: Int,
                                   calendar: Calendar = .current) -> Int {
        switch rule {
        case .everyNDays(let days):
            return completedOn + days

        case .daily(let every, let anchor):
            let base = anchorDay(dueDay: dueDay, completedOn: completedOn, anchor: anchor)
            return base + every

        case .weekly(let every, let weekdays, let anchor):
            let base = anchorDay(dueDay: dueDay, completedOn: completedOn, anchor: anchor)
            return nextWeekly(after: base, every: every, weekdays: weekdays, calendar: calendar)

        case .monthly(let every, let day, let anchor):
            let base = anchorDay(dueDay: dueDay, completedOn: completedOn, anchor: anchor)
            return nextMonthly(after: base, every: every, monthDay: day, calendar: calendar)

        case .yearly(let month, let day, let anchor):
            let base = anchorDay(dueDay: dueDay, completedOn: completedOn, anchor: anchor)
            return nextYearly(after: base, month: month, day: day, calendar: calendar)
        }
    }

    private static func anchorDay(dueDay: Int, completedOn: Int, anchor: RecurrenceAnchor) -> Int {
        switch anchor {
        case .fromDueDay: return max(dueDay, completedOn)
        case .fromCompletionDay: return completedOn
        }
    }

    // MARK: - Weekly

    /// Steps day by day from `after + 1` until an ISO weekday in `weekdays`,
    /// then, for `every > 1`, adds `(every - 1)` weeks from that occurrence.
    private static func nextWeekly(after: Int, every: Int, weekdays: Set<Int>,
                                    calendar: Calendar) -> Int {
        var candidate = after + 1
        // weekdays is validated non-empty by RecurrenceRule.parse and every
        // caller; a 7-day scan always finds a match.
        for _ in 0..<7 {
            if weekdays.contains(isoWeekday(of: candidate, calendar: calendar)) { break }
            candidate += 1
        }
        return candidate + (every - 1) * 7
    }

    private static func isoWeekday(of day: Int, calendar: Calendar) -> Int {
        // Foundation's Calendar.weekday is 1 = Sunday ... 7 = Saturday.
        // ISO wants 1 = Monday ... 7 = Sunday.
        let date = Day.date(day, calendar: calendar)
        let sundayFirst = calendar.component(.weekday, from: date)
        return sundayFirst == 1 ? 7 : sundayFirst - 1
    }

    // MARK: - Monthly

    /// Advances by `every` months from `after`'s month, clamping the target
    /// day to that month's length (31 -> 28/29 in February). If the result
    /// does not land strictly after `after`, advances one more `every`.
    private static func nextMonthly(after: Int, every: Int, monthDay: Int,
                                     calendar: Calendar) -> Int {
        let afterDate = Day.date(after, calendar: calendar)
        var monthsToAdd = every
        while true {
            guard let advanced = calendar.date(byAdding: .month, value: monthsToAdd, to: afterDate) else {
                monthsToAdd += every
                continue
            }
            let clampedDate = clampToDay(monthDay, inMonthOf: advanced, calendar: calendar)
            let clampedDay = Day.from(clampedDate, calendar: calendar)
            if clampedDay > after { return clampedDay }
            monthsToAdd += every
        }
    }

    private static func clampToDay(_ day: Int, inMonthOf date: Date, calendar: Calendar) -> Date {
        let range = calendar.range(of: .day, in: .month, for: date) ?? (1..<29)
        let lastDay = range.upperBound - 1
        let target = min(day, lastDay)
        var comps = calendar.dateComponents([.year, .month], from: date)
        comps.day = target
        return calendar.date(from: comps) ?? date
    }

    // MARK: - Yearly

    /// One occurrence a year on `month`/`day`. 29 Feb clamps to 28 Feb in a
    /// non-leap year. Advances a year at a time until strictly after `after`.
    private static func nextYearly(after: Int, month: Int, day: Int, calendar: Calendar) -> Int {
        let afterDate = Day.date(after, calendar: calendar)
        var year = calendar.component(.year, from: afterDate)
        while true {
            year += 1
            var comps = DateComponents()
            comps.year = year
            comps.month = month
            comps.day = 1
            guard let firstOfMonth = calendar.date(from: comps) else { continue }
            let candidateDate = clampToDay(day, inMonthOf: firstOfMonth, calendar: calendar)
            let candidateDay = Day.from(candidateDate, calendar: calendar)
            if candidateDay > after { return candidateDay }
        }
    }
}
