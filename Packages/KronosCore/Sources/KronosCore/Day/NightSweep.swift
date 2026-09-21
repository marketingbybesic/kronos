// The housekeeping that runs once per day change. Purges soft-deleted rows older than 30 days
// via the store's own `purgeDeletedOlderThan`, which its doc comment already names as
// "run by DayChangeCoordinator" (Store/TaskStore+Mutations.swift).
//
// NEVER writes `dueDay` or `originalDueDay`. Overdue carry is read-only
// (`KTask.carryDays(today:)` in Contracts.swift): a rollover job that mutates due dates,
// plus a stored carry counter, is a defect class this design avoids entirely.
//
// Contract gap: there is no `clearDoneFromOrdoNoUndo()` on `TaskStoring`, only the
// undo-registering `clearDoneFromOrdo()`. A background sweep
// calling it would push a snapshot the user never asked to undo, silently shifting Cmd-Z's
// meaning after every overnight run. This file therefore does NOT clear Ordo's closed rows —
// that needs a no-undo variant added to `TaskStoring`/`OrdoEngine` first.

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
        defaults.setInteger(today, forKey: Self.lastRunDayKey)
        store.purgeDeletedOlderThan(days: Self.purgeWindowDays, now: clock.now)
    }
}
