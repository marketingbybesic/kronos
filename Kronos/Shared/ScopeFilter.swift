// SCOPE FILTER — the ONE definition of what belongs in a `ListScope`. Unifies two earlier,
// separately-written versions of this same filter. The sidebar's count and the list's rows
// must come from the same rule, or the badge says 7 while the list shows 6.

import Foundation
import KronosCore

enum ScopeFilter {
    /// LIST MEMBERSHIP: does `task` belong to `scope`, before the user's own view options?
    /// Fixed scopes are open-only by definition. Project / area scopes include closed tasks —
    /// whether those are SHOWN is the list's `ViewOptions.showCompleted`, not membership.
    /// A saved view has no base membership: its own `KFilter` is the whole rule.
    /// A task of an archived project belongs to no scope except that project itself, so it leaves
    /// Today, Next 7, Waiting, Someday, All, areas and saved views along with the project.
    static func matches(_ task: KTask, scope: ListScope, today: Int) -> Bool {
        // An undecided agent proposal (reviewRaw 1) is in no scope; only the Review queue shows it.
        guard task.deletedAt == nil, task.reviewRaw != 1 else { return false }
        if task.isProjectArchived, !isProjectScope(scope) { return false }
        let isOpen = KStatus.open.contains(task.status)
        switch scope {
        case .inbox:
            return task.projectID == nil && task.status != .someday && isOpen
        case .today:
            // Schedule day (planned day, else effective due): an undone subtask due today or
            // overdue brings its parent in (the subtask itself is never a row of its own), and a
            // task planned for a later day stays out until that day.
            return DueScope.isToday(task, today: today)
        case .next7:
            return DueScope.isNext7(task, today: today)
        case .waiting:
            return task.status == .waiting
        case .someday:
            return task.status == .someday
        case .all:
            return isOpen
        case .project(let id):
            return task.projectID == id
        case .area(let id):
            return task.areaID == id
        case .savedView:
            return true
        }
    }

    private static func isProjectScope(_ scope: ListScope) -> Bool {
        if case .project = scope { return true }
        return false
    }

    /// SIDEBAR COUNT: what the badge next to a scope shows — always OPEN members only, so the
    /// number answers "how much is left here". Saved views are counted by their own filter by
    /// the caller, never here.
    static func countsInSidebar(_ task: KTask, scope: ListScope, today: Int) -> Bool {
        if case .savedView = scope { return false }
        return matches(task, scope: scope, today: today) && KStatus.open.contains(task.status)
    }

    /// The scope's base membership expressed as a `KFilter`, ANDed with the user's view-options
    /// filter by the caller. `.savedView` returns `.empty` (its own filter is read separately).
    static func baseFilter(for scope: ListScope) -> KFilter {
        var f = KFilter.empty
        switch scope {
        case .inbox:
            f.noProject = true
            f.statuses = KStatus.openRaw.filter { $0 != KStatus.someday.rawValue }
        case .today:
            f.due = .today
            f.statuses = KStatus.openRaw
        case .next7:
            f.due = .next7
            f.statuses = KStatus.openRaw
        case .waiting:
            f.statuses = [KStatus.waiting.rawValue]
        case .someday:
            f.statuses = [KStatus.someday.rawValue]
        case .all:
            f.statuses = KStatus.openRaw
        case .project(let id):
            f.projectIDs = [id]
        case .area(let id):
            f.areaIDs = [id]
        case .savedView:
            break
        }
        return f
    }
}
