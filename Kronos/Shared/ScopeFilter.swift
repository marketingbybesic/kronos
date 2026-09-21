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
    static func matches(_ task: KTask, scope: ListScope, today: Int) -> Bool {
        guard task.deletedAt == nil else { return false }
        let isOpen = KStatus.open.contains(task.status)
        switch scope {
        case .inbox:
            return task.projectID == nil && task.status != .someday && isOpen
        case .today:
            guard isOpen, let due = task.dueDay else { return false }
            return due <= today
        case .next7:
            guard isOpen, let due = task.dueDay else { return false }
            return due >= today && due <= today + 7
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
