// "Show completed": which statuses a list may hold, and which closed tasks belong to which list.
//
// The fixed lists (Inbox, Today, Next 7 days, All) are open-only by definition. The switch widens
// them, so a task that was done is still found where it lived, without flooding a date list with
// all of history: Today and Next 7 days take only what was completed today (plus, for Next 7 days,
// closed tasks scheduled inside its window). Waiting and Someday hold one status each; a closed task
// can never be in them, so the switch does nothing there (the screen hides it).
//
// Pure and synchronous: the app's ScopeFilter and ListContext call these, and a hand table tests them.

import Foundation

public enum ListStatusPolicy {

    /// The kinds of list the rule tells apart.
    public enum ScopeKind: Equatable, Sendable {
        case inbox, today, next7, all, waiting, someday
        /// A project, an area or a saved view: closed tasks are members, display decides.
        case container
    }

    /// The status list the list's filter must use.
    ///
    /// - Parameters:
    ///   - base: the scope's own statuses (`ScopeFilter.baseFilter`), `[]` for a container.
    ///   - user: the statuses the person filtered on, `[]` when none.
    ///   - showCompleted: the display switch.
    /// - Returns: `user` when set (the person's explicit choice wins); else the base; widened to the
    ///   closed statuses when `showCompleted` and the base is an open-set base; `[]` means "any".
    public static func effectiveStatuses(base: [Int], user: [Int], showCompleted: Bool) -> [Int] {
        if !user.isEmpty { return user }
        if !showCompleted { return base.isEmpty ? KStatus.openRaw : base }
        if base.isEmpty { return [] }
        if base.contains(where: { KStatus.closedRaw.contains($0) }) { return base }
        // An open-set base (Inbox without Someday, Today, Next 7, All) gains the closed statuses.
        // A single-status base (Waiting, Someday) stays as it is.
        let openSetWithoutSomeday = Set(KStatus.openRaw).subtracting([KStatus.someday.rawValue])
        guard openSetWithoutSomeday.isSubset(of: Set(base)) else { return base }
        return base + KStatus.closedRaw
    }

    /// True when closed tasks may be members of the list: the switch is on, or the person filtered on a
    /// closed status (asking for "Done" must find them even with the switch off).
    public static func includesClosed(showCompleted: Bool, userStatuses: [Int], statusesNegated: Bool) -> Bool {
        if showCompleted { return true }
        return !statusesNegated && userStatuses.contains(where: { KStatus.closedRaw.contains($0) })
    }

    /// Whether a CLOSED task belongs to the list of `kind` once closed tasks are included. The caller
    /// has already checked what is common to every list (not deleted, not pending review, project
    /// archived rule) and, for the Inbox, that the task has no project and is not Someday.
    ///
    /// - Parameters:
    ///   - completedDay: the day the task was completed, nil when it has no completion time.
    ///   - scheduleDay: its planned day, else its due day (`KTask.scheduleDay`).
    public static func admitsClosed(_ kind: ScopeKind, completedDay: Int?, scheduleDay: Int?, today: Int) -> Bool {
        switch kind {
        case .all, .inbox, .container:
            return true
        case .today:
            return completedDay == today
        case .next7:
            if completedDay == today { return true }
            guard let day = scheduleDay else { return false }
            return day >= today && day <= today + 7
        case .waiting, .someday:
            return false
        }
    }
}
