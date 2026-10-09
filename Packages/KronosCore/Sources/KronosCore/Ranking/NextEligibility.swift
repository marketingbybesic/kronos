import Foundation
import SwiftData

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
        // Perf: `DependencyGraph.blocked` builds an id->open Set over the WHOLE `lookup`
        // pool on every call, even though its own inner loop only ever looks at tasks with a
        // non-empty `waitsOnIDs`. Most tasks have none (dependencies are rare), so skip the
        // call — and the Set build — entirely when this task carries no dependency at all;
        // `blocked(in: [task], lookup:)` would return empty in that case anyway (confirmed by
        // reading its body: `for t in tasks where !t.waitsOnIDs.isEmpty`). At launch this is
        // called once per Today-list candidate (`NextFallback.todayHead`), so at scale it was
        // an O(candidates × lookup) cost for work that never changes the answer.
        if !task.waitsOnIDs.isEmpty, !DependencyGraph.blocked(in: [task], lookup: lookup).isEmpty { return .blocked }
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
        // Launch fires several back-to-back menu-bar/MCP renders before the list mounts
        // (UserDefaults-change-driven re-renders, step trace: a dozen+ calls within the same
        // launch, all with nothing in the store having changed between them), each repeating
        // the full scan below. A short time-boxed cache (keyed to this store + the exact
        // question asked) collapses a burst into one real fetch. This is a read-time cache
        // only — nothing invalidates it early on a write — so it trades up to half a second of
        // "today" staleness on this cold-launch/no-list-mounted fallback path specifically
        // (never the live list, which always re-derives its own head), the same ballpark
        // MenuBarQuiet's own minute tick already accepts for the bar's other quiet-line data.
        let key = ObjectIdentifier(store)
        let now = Date()
        if let c = cache, c.key == key, c.today == today, c.limit == limit, now.timeIntervalSince(c.at) < cacheWindow {
            return c.result
        }
        // `isToday` reads `effectiveDue`, which reads `children` (a to-many relationship) for
        // every candidate, to check for an open subtask pulling the due day earlier. A plain
        // `store.allTasks()` fetch never prefetches relationships, so that touch faulted each
        // task's children in its own round trip — prefetching keeps the exact same rule, batched
        // into one query instead of thousands (step PERF: both this and the cache above were
        // needed — at 5,000 tasks the base fetch+decode alone still costs ~230 ms, and this
        // launch-time fallback was being asked the identical question a dozen times per launch).
        var d = FetchDescriptor<KTask>(predicate: TaskStore.topLevelPredicate)
        d.relationshipKeyPathsForPrefetching = [\.children]
        let all = (try? store.context.fetch(d)) ?? []
        let members = all.filter { isToday($0, today: today) }
        let sorted = KTaskSorter.sorted(members, by: KSortDescriptor.default)
        let result = Array(sorted.lazy.filter { NextEligibility.isEligible($0, lookup: all) }.prefix(limit).map(\.id))
        cache = Cache(key: key, today: today, limit: limit, at: now, result: result)
        return result
    }

    private struct Cache { let key: ObjectIdentifier; let today: Int; let limit: Int; let at: Date; let result: [UUID] }
    @MainActor private static var cache: Cache?
    private static let cacheWindow: TimeInterval = 0.5

    static func isToday(_ task: KTask, today: Int) -> Bool {
        DueScope.isToday(task, today: today)
    }
}
