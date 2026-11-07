#if os(macOS)
import Testing
import Foundation
@testable import KronosCore

/// Hand-written expectation table for `WeekBuckets`, compiled against the real source.
@MainActor
struct WeekBucketsTests {
    let startDay = 20000

    private func task(_ title: String, status: KStatus = .todo, plannedDay: Int? = nil, dueDay: Int? = nil) -> KTask {
        let t = KTask(title: title)
        t.status = status
        t.plannedDay = plannedDay
        t.dueDay = dueDay
        return t
    }

    @Test func sevenDaysInOrderStartingAtStartDay() {
        let buckets = WeekBuckets.buckets(tasks: [], startDay: startDay)
        #expect(buckets.count == 7)
        #expect(buckets.map(\.day) == Array(startDay..<(startDay + 7)))
        #expect(buckets.allSatisfy { $0.plannedCount == 0 && $0.dueCount == 0 })
    }

    @Test func plannedAndDueCountSeparatelyAndCanCoincide() {
        let t1 = task("planned only", plannedDay: startDay)
        let t2 = task("due only", dueDay: startDay)
        let t3 = task("both on day 2", plannedDay: startDay + 2, dueDay: startDay + 2)
        let buckets = WeekBuckets.buckets(tasks: [t1, t2, t3], startDay: startDay)

        #expect(buckets[0].plannedCount == 1 && buckets[0].dueCount == 1)
        #expect(buckets[1].plannedCount == 0 && buckets[1].dueCount == 0)
        #expect(buckets[2].plannedCount == 1 && buckets[2].dueCount == 1, "the same task counts in both")
    }

    @Test func closedTasksNeverCount() {
        let done = task("done today", status: .done, plannedDay: startDay, dueDay: startDay)
        let canceled = task("canceled", status: .canceled, plannedDay: startDay, dueDay: startDay)
        let buckets = WeekBuckets.buckets(tasks: [done, canceled], startDay: startDay)
        #expect(buckets[0].plannedCount == 0 && buckets[0].dueCount == 0)
    }

    @Test func daysOutsideTheWindowAreNotCounted() {
        let before = task("yesterday", plannedDay: startDay - 1)
        let after = task("day 8", plannedDay: startDay + 7)
        let buckets = WeekBuckets.buckets(tasks: [before, after], startDay: startDay)
        #expect(buckets.allSatisfy { $0.plannedCount == 0 })
    }

    @Test func BREAK_wouldFailIfClosedTasksCounted() {
        // Positive control: an open task on the same day as the `closedTasksNeverCount` fixture
        // MUST count, proving the zero result above is not a tautology.
        let open = task("open today", plannedDay: startDay)
        let buckets = WeekBuckets.buckets(tasks: [open], startDay: startDay)
        #expect(buckets[0].plannedCount == 1)
    }
}
#endif
