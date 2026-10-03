// Today, split in two: what belongs to today and what has been waiting longer. The second part
// is the collapsed "Earlier" section whose header carries the one-step "Fresh start".

import Foundation

/// Where a Fresh start sends the tasks of the Earlier section.
public enum FreshStartTarget: Equatable, Sendable {
    case today, tomorrow, someday
}

public enum TodayPartition {

    /// Splits the rows of Today, keeping their order. A row is EARLIER when it has been carried
    /// at least once (`carryCount >= 1`) or its schedule day is before `today`: the planned day
    /// when there is one, else the effective due day. Everything else is current.
    public static func split(rows: [KTask], today: Int) -> (current: [KTask], earlier: [KTask]) {
        var current: [KTask] = []
        var earlier: [KTask] = []
        for row in rows {
            if isEarlier(row, today: today) { earlier.append(row) } else { current.append(row) }
        }
        return (current, earlier)
    }

    public static func isEarlier(_ task: KTask, today: Int) -> Bool {
        if task.carryCount >= 1 { return true }
        guard let day = task.scheduleDay else { return false }
        return day < today
    }
}
