// Effective due: what the date-driven views (Today, overdue, deadline filters and sorting,
// the menu-bar queue) read instead of the task's own `dueDay`. `KTask.effectiveDue` itself
// lives with the model in Contracts.swift; this file adds the pieces a row needs to SHOW
// why a task is in a list although its own date says otherwise.

import Foundation

extension KTask {

    /// The day the task belongs to for the date-driven lists: the planned day when the person
    /// set one, else the effective due day. Nil for an unscheduled task.
    public var scheduleDay: Int? { plannedDay ?? effectiveDue }

    /// True when an undone subtask pulls the effective due day earlier than the task's own
    /// day (or the task has no day at all), so the row should say the date comes from a step.
    public var isDueDrivenBySubtask: Bool {
        guard let effective = effectiveDue else { return false }
        return effective != dueDay
    }

    /// True for the undone subtask that is the reason `effectiveDue` differs from `dueDay`.
    /// Several steps sharing the earliest day all qualify. Always false for a done step and
    /// whenever the task's own day already explains the effective day.
    public func isDueDriver(_ subtask: KTask) -> Bool {
        guard isDueDrivenBySubtask, KStatus.open.contains(subtask.status), let day = subtask.dueDay else { return false }
        return day == effectiveDue
    }
}

/// Where a "Make subtask" keyboard command lands: the task directly above in the list the
/// user is looking at.
public enum KeyboardNesting {

    /// The row directly above `id` in `rows` (display order), or nil when `id` is first or
    /// not in the list.
    public static func taskAbove(_ id: UUID, in rows: [UUID]) -> UUID? {
        guard let i = rows.firstIndex(of: id), i > 0 else { return nil }
        return rows[i - 1]
    }
}

/// Membership of the date scopes in the sidebar (Today, Next 7 days). One definition, read by
/// the app's `ScopeFilter` and by the unit tests: both go through the schedule day, so a
/// task whose undone subtask is due appears here as ONE row (the parent), never as the subtask.
///
/// The schedule day is the day the person means to do the task (`plannedDay`) when there is
/// one, else the effective due day. A planned day therefore wins over a deadline in both
/// directions: planning an overdue task for tomorrow takes it out of Today until tomorrow,
/// and a task planned for today is in Today whatever its deadline says.
public enum DueScope {

    /// Open and scheduled for today or earlier (overdue tasks are carried into Today).
    public static func isToday(_ task: KTask, today: Int) -> Bool {
        guard KStatus.open.contains(task.status) else { return false }
        return isScheduledByToday(task, today: today)
    }

    /// Open and scheduled from today through the next seven days.
    public static func isNext7(_ task: KTask, today: Int) -> Bool {
        guard KStatus.open.contains(task.status) else { return false }
        return isScheduled(task, from: today, through: today + 7)
    }

    /// Status-free: the schedule day is today or earlier. Shared with `KFilter`'s Today window.
    public static func isScheduledByToday(_ task: KTask, today: Int) -> Bool {
        guard let day = task.scheduleDay else { return false }
        return day <= today
    }

    /// Status-free: the schedule day lies in `from...through`. Shared with `KFilter`'s forward windows.
    public static func isScheduled(_ task: KTask, from: Int, through: Int) -> Bool {
        guard let day = task.scheduleDay else { return false }
        return day >= from && day <= through
    }
}
