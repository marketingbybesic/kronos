// Kronos v1.2 Phase 2 slice F3: the Today week strip. Seven days, each the count of OPEN tasks
// planned for that day and the count due that day — two independent counts (a task counts in
// both when its planned day and its deadline happen to be the same day). Closed tasks never
// count, matching the sidebar's own "always open members" rule (ScopeFilter.countsInSidebar):
// the strip answers "what's left", not a history of what happened.
import Foundation

/// One day's two counts.
public struct WeekDayBucket: Equatable, Sendable {
    public let day: Int
    public let plannedCount: Int
    public let dueCount: Int
}

public enum WeekBuckets {
    /// `days` consecutive days starting at `startDay`, in order.
    public static func buckets(tasks: [KTask], startDay: Int, days: Int = 7) -> [WeekDayBucket] {
        let open = tasks.filter { KStatus.open.contains($0.status) }
        return (0..<days).map { offset in
            let day = startDay + offset
            let planned = open.filter { $0.plannedDay == day }.count
            let due = open.filter { $0.effectiveDue == day }.count
            return WeekDayBucket(day: day, plannedCount: planned, dueCount: due)
        }
    }
}
