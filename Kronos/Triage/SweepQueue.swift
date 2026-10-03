// Kronos/Triage/SweepQueue.swift
//
// The queue behind Sweep, the short review of what has gone quiet: someday tasks nobody has
// touched for two weeks, waiting tasks that have not moved for a week, and open tasks untouched
// for three weeks. "Untouched" is the task's `updatedAt`; no schema field is involved.
// Pure (Foundation + KronosCore, an injected clock), so scripts/triage-lock-selftest.swift can
// compile it next to a hand-written table.
import Foundation
import KronosCore

enum SweepQueue {
    static let somedayDays = 14
    static let waitingDays = 7
    static let openDays = 21

    /// Whole calendar days between the last touch and `now`.
    static func idleDays(_ task: KTask, now: Date, calendar: Calendar) -> Int {
        max(0, Day.from(now, calendar: calendar) - Day.from(task.updatedAt, calendar: calendar))
    }

    /// True when the task belongs in a sweep right now. A task still waiting for its planned or
    /// due day is not stale; a child, a deleted task, and one an agent proposed and nobody has
    /// reviewed yet are not the person's to sweep.
    static func qualifies(_ task: KTask, now: Date, calendar: Calendar) -> Bool {
        guard !task.isSubtask, task.deletedAt == nil, task.reviewRaw != 1 else { return false }
        let today = Day.from(now, calendar: calendar)
        if let due = task.dueDay, due > today { return false }
        if let planned = task.plannedDay, planned > today { return false }
        let idle = idleDays(task, now: now, calendar: calendar)
        switch task.status {
        case .someday: return idle >= somedayDays
        case .waiting: return idle >= waitingDays
        case .todo, .inProgress: return idle >= openDays
        case .done, .canceled: return false
        }
    }

    /// Longest-quiet first, id as a stable tie-break, so a sitting never reshuffles.
    static func ordered(in tasks: [KTask], now: Date, calendar: Calendar) -> [KTask] {
        tasks
            .filter { qualifies($0, now: now, calendar: calendar) }
            .sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
                return $0.id.uuidString < $1.id.uuidString
            }
    }
}

/// What a sweep card can do with a task. Raw key letters live in the view; this is the meaning.
enum SweepAction: Equatable {
    case keep, planToday, someday, delete, done
}
