import Foundation

/// Which tasks may be offered as "next": the menu bar label, the Now card, the MCP `next` pick.
/// Pure and fetch-free like `RankingEngine`; the store entry points only gather the pool.
public enum NextEligibility {

    /// A task that is not a next action, with the reason. Order of the checks is the order of
    /// the cases.
    public enum Exclusion: Equatable, Sendable {
        case deleted
        case closed          // done or canceled (any status outside `KStatus.open`)
        case projectArchived
        case reviewPending   // an agent result waits for the person's review
        case blocked         // waits on a task that is still open
    }

    /// `reviewRaw` value of a task whose agent result is pending review.
    public static let reviewPending = 1

    /// Why `task` cannot be next, nil when it can. `lookup` is the full live pool: it decides
    /// whether a waited-on task is still open (an id absent from it no longer blocks).
    public static func exclusion(of task: KTask, lookup: [KTask]) -> Exclusion? {
        if task.deletedAt != nil { return .deleted }
        if !KStatus.open.contains(task.status) { return .closed }
        if task.isProjectArchived { return .projectArchived }
        if task.reviewRaw == reviewPending { return .reviewPending }
        if !DependencyGraph.blocked(in: [task], lookup: lookup).isEmpty { return .blocked }
        return nil
    }

    public static func isEligible(_ task: KTask, lookup: [KTask]) -> Bool {
        exclusion(of: task, lookup: lookup) == nil
    }

    @MainActor
    public static func isEligible(_ task: KTask, store: TaskStore) -> Bool {
        isEligible(task, lookup: store.allTasks())
    }

    /// First eligible task of `rows` (the list as shown, in display order), nil when none.
    public static func firstEligible(in rows: [KTask], lookup: [KTask]) -> KTask? {
        rows.first { isEligible($0, lookup: lookup) }
    }

    /// The next task for a list: a pinned task wins while it is still open and not deleted
    /// (a pin overrides review and block, the person chose it), else the first eligible row.
    public static func pick(pinned: UUID?, rows: [KTask], lookup: [KTask]) -> KTask? {
        if let pinned, let t = lookup.first(where: { $0.id == pinned }),
           t.deletedAt == nil, KStatus.open.contains(t.status) {
            return t
        }
        return firstEligible(in: rows, lookup: lookup)
    }
}

/// Next-task source when no list is on screen (cold launch, menu bar only, MCP).
public enum NextFallback {

    /// Ids of the first `limit` eligible tasks of Today, in the default list sort. Today is the
    /// Today list's own membership (`DueScope.isToday`): open, and the schedule day (planned day
    /// when set, else the effective due day) is today or earlier. A planned day wins over the
    /// deadline both ways, so an overdue task planned for a later day is not in Today.
    @MainActor
    public static func todayHead(store: TaskStore, today: Int, limit: Int) -> [UUID] {
        guard limit > 0 else { return [] }
        let all = store.allTasks()
        let members = all.filter { isToday($0, today: today) }
        let sorted = KTaskSorter.sorted(members, by: KSortDescriptor.default)
        return Array(sorted.lazy.filter { NextEligibility.isEligible($0, lookup: all) }.prefix(limit).map(\.id))
    }

    static func isToday(_ task: KTask, today: Int) -> Bool {
        DueScope.isToday(task, today: today)
    }
}
