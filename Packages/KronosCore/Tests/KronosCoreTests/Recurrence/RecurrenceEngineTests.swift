import Testing
import Foundation
@testable import KronosCore

private func zagrebCalendar() -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Europe/Zagreb")!
    return cal
}

@Test func monthlyOnThe31stClampsToMonthEnd() {
    let cal = zagrebCalendar()
    // Due Jan 31, completed on time -> next occurrence Feb 28 (2027, non-leap).
    let jan31 = Day.from(dateYMD(2027, 1, 31, cal), calendar: cal)
    let rule = RecurrenceRule.monthly(every: 1, day: 31, anchor: .fromDueDay)
    let next = RecurrenceEngine.nextDueDay(after: jan31, rule: rule, completedOn: jan31, calendar: cal)
    let comps = cal.dateComponents([.year, .month, .day], from: Day.date(next, calendar: cal))
    #expect(comps.year == 2027 && comps.month == 2 && comps.day == 28)
}

@Test func dailyAcrossDSTEndKeepsCalendarDay() {
    // Europe/Zagreb DST ends 2026-10-25. A daily task due the 24th, completed
    // on time, must recur on the 25th — the calendar day, not shifted by the
    // one-hour fallback that would occur under raw 86400-second arithmetic.
    let cal = zagrebCalendar()
    let oct24 = Day.from(dateYMD(2026, 10, 24, cal), calendar: cal)
    let rule = RecurrenceRule.daily(every: 1, anchor: .fromDueDay)
    let next = RecurrenceEngine.nextDueDay(after: oct24, rule: rule, completedOn: oct24, calendar: cal)
    let comps = cal.dateComponents([.year, .month, .day], from: Day.date(next, calendar: cal))
    #expect(comps.year == 2026 && comps.month == 10 && comps.day == 25)
}

@Test func everyNDaysCountsFromCompletionDay() {
    // Due day is irrelevant to afterCompletion/everyNDays: it always counts
    // from the day actually completed, even if that is long after due.
    let due = 20_000
    let completedLate = due + 10
    let rule = RecurrenceRule.everyNDays(3)
    let next = RecurrenceEngine.nextDueDay(after: due, rule: rule, completedOn: completedLate)
    #expect(next == completedLate + 3)
}

@Test func weeklySkipsToNextSelectedWeekday() {
    let cal = zagrebCalendar()
    // 2026-09-21 is a Monday (iso 1). Rule fires Mon(1)/Wed(3). Due Monday,
    // completed on time -> next occurrence is Wednesday the 23rd.
    let monday = Day.from(dateYMD(2026, 9, 21, cal), calendar: cal)
    let rule = RecurrenceRule.weekly(every: 1, weekdays: [1, 3], anchor: .fromDueDay)
    let next = RecurrenceEngine.nextDueDay(after: monday, rule: rule, completedOn: monday, calendar: cal)
    let comps = cal.dateComponents([.year, .month, .day], from: Day.date(next, calendar: cal))
    #expect(comps.year == 2026 && comps.month == 9 && comps.day == 23)
}

@Test func leapDayYearlyFallsBackToFeb28() {
    let cal = zagrebCalendar()
    // Due 2024-02-29 (leap year), completed on time -> next year 2025 is not
    // a leap year, so the occurrence clamps to Feb 28.
    let leapDay = Day.from(dateYMD(2024, 2, 29, cal), calendar: cal)
    let rule = RecurrenceRule.yearly(month: 2, day: 29, anchor: .fromDueDay)
    let next = RecurrenceEngine.nextDueDay(after: leapDay, rule: rule, completedOn: leapDay, calendar: cal)
    let comps = cal.dateComponents([.year, .month, .day], from: Day.date(next, calendar: cal))
    #expect(comps.year == 2025 && comps.month == 2 && comps.day == 28)
}

@Test func missedOccurrencesCollapseToFirstFutureDate() {
    // Daily due Monday, completed Thursday -> next is Friday, not Tuesday:
    // max(dueDay, completedOn) anchors the search, per data-model.md §6.2.
    let cal = zagrebCalendar()
    let monday = Day.from(dateYMD(2026, 9, 21, cal), calendar: cal)
    let thursday = monday + 3
    let rule = RecurrenceRule.daily(every: 1, anchor: .fromDueDay)
    let next = RecurrenceEngine.nextDueDay(after: monday, rule: rule, completedOn: thursday, calendar: cal)
    #expect(next == thursday + 1)
}

@Test func propertyNextIsAlwaysStrictlyGreaterAndStable() {
    let cal = zagrebCalendar()
    var rng = SplitMix64(seed: 42)
    for _ in 0..<2000 {
        let due = Int(rng.next(in: 15_000...25_000))
        let lateBy = Int(rng.next(in: 0...40))
        let completed = due + lateBy
        let rule = randomRule(&rng)

        let next = RecurrenceEngine.nextDueDay(after: due, rule: rule, completedOn: completed, calendar: cal)
        #expect(next > due, "rule \(rule.wireFormat) due=\(due) completed=\(completed) next=\(next)")
        #expect(next > completed, "rule \(rule.wireFormat) due=\(due) completed=\(completed) next=\(next)")

        // Stability: re-applying with the new day as both due and completion
        // (on time) always advances further, never regresses or loops.
        let again = RecurrenceEngine.nextDueDay(after: next, rule: rule, completedOn: next, calendar: cal)
        #expect(again > next, "re-apply rule \(rule.wireFormat) next=\(next) again=\(again)")
    }
}

// MARK: - Test helpers

private func dateYMD(_ y: Int, _ m: Int, _ d: Int, _ cal: Calendar) -> Date {
    var comps = DateComponents()
    comps.year = y; comps.month = m; comps.day = d; comps.hour = 12
    return cal.date(from: comps)!
}

/// Deterministic PRNG so the 2,000-case property test is reproducible.
private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func nextRaw() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func next(in range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(nextRaw() % span)
    }
}

private func randomRule(_ rng: inout SplitMix64) -> RecurrenceRule {
    let anchor: RecurrenceAnchor = rng.next(in: 0...1) == 0 ? .fromDueDay : .fromCompletionDay
    switch rng.next(in: 0...4) {
    case 0:
        return .daily(every: rng.next(in: 1...5), anchor: anchor)
    case 1:
        var days = Set<Int>()
        let count = rng.next(in: 1...3)
        while days.count < count { days.insert(rng.next(in: 1...7)) }
        return .weekly(every: rng.next(in: 1...3), weekdays: days, anchor: anchor)
    case 2:
        return .monthly(every: rng.next(in: 1...3), day: rng.next(in: 1...31), anchor: anchor)
    case 3:
        return .yearly(month: rng.next(in: 1...12), day: rng.next(in: 1...31), anchor: anchor)
    default:
        return .everyNDays(rng.next(in: 1...10))
    }
}
