// The housekeeping that runs once per day change.
//
//   1. Purges soft-deleted rows older than 30 days via the store's own `purgeDeletedOlderThan`.
//   2. Rolls the plan forward. An open task planned for a day before today moves to today, with
//      no carry: a plan that slipped is not a failure to count.
//   3. Counts carry. An open task with no planned day whose deadline is behind it gets
//      `carryCount += 1` for every day that passed since the last sweep (at most the days it is
//      late), and `originalDueDay` is recorded once. When the count reaches the dread threshold
//      the task is flagged (`DreadRules`), on that day only.
//
// NEVER writes `dueDay`: the deadline stays exactly what the person set. Every write goes
// through `updateNoUndo`, so Cmd-Z keeps meaning "undo what I just did" after an overnight run.
//
// Contract gap: there is no `clearDoneFromOrdoNoUndo()` on `TaskStoring`, only the
// undo-registering `clearDoneFromOrdo()`. A background sweep calling it would push a snapshot
// the user never asked to undo. This file therefore does NOT clear Ordo's closed rows.

import Foundation

/// Runs the day's housekeeping exactly once, guarded by its own stored day
/// number so re-entrant calls the same day are no-ops.
@MainActor
public final class NightSweep {
    public static let lastRunDayKey = "kronos.nightSweep.lastRunDay"
    public static let purgeWindowDays = 30

    private let store: TaskStoring
    private let clock: KronosClock
    private let defaults: DayKeyValueStore

    public init(store: TaskStoring, clock: KronosClock, defaults: DayKeyValueStore) {
        self.store = store
        self.clock = clock
        self.defaults = defaults
    }

    /// Call on `.kronosDayDidChange`. Idempotent: running it twice on the
    /// same local day performs the purge once.
    public func runIfNeeded() {
        let today = clock.today()
        guard defaults.integer(forKey: Self.lastRunDayKey) != today else { return }
        let previous = defaults.integer(forKey: Self.lastRunDayKey)
        defaults.setInteger(today, forKey: Self.lastRunDayKey)
        store.purgeDeletedOlderThan(days: Self.purgeWindowDays, now: clock.now)
        rollPlanAndCountCarry(today: today, daysSinceLastSweep: previous == 0 ? 1 : max(1, today - previous))
    }

    /// Steps 2 and 3 above. Public so a test can drive one day without the day-key bookkeeping.
    public func rollPlanAndCountCarry(today: Int, daysSinceLastSweep: Int) {
        for task in store.allTasks() where KStatus.open.contains(task.status) {
            let id = task.id
            if let planned = task.plannedDay {
                if planned < today { store.updateNoUndo(id) { $0.plannedDay = today } }
                continue
            }
            guard KStatus.active.contains(task.status),
                  let late = task.effectiveDue, late < today else { continue }
            let before = task.carryCount
            let step = min(daysSinceLastSweep, today - late)
            store.updateNoUndo(id) { t in
                t.carryCount = before + step
                if t.originalDueDay == nil { t.originalDueDay = t.dueDay ?? late }
                if DreadRules.carryCrossesThreshold(from: before, to: t.carryCount) { t.dread = true }
            }
        }
    }
}
