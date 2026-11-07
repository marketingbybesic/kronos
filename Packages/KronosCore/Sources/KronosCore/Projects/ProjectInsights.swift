// Kronos v1.2 Phase 2 slice F ("Projects that explain themselves"). Pure dependency-graph reads
// over a task set already narrowed to one scope (a project's own top-level tasks, or whatever a
// caller passes) — the project header strip (F1) and the "gate" mark (plan section F's closing
// Milestones note: a task ≥2 open tasks wait on) both read these.
//
// Phase 3 audit (slice audit5) fold decision: kept deliberately separate from FlowLayout.build,
// not folded into one source, even though both modules are merged now. `canStart`/`isGate`
// encode the SAME "open task, nothing it waits on is still open" rule as FlowLayout's own
// depth-0 column / edge-count-derived gate (ProjectInsightsTests.swift's own
// `projectInsightsAgreesWithFlowLayoutDepthZeroOnAnAcyclicGraph` pins the two to agree on a
// representative acyclic graph instead). Why not fold: `FlowLayout.build` is O(n) PER CALL (a
// full DFS + edge list + column sort/cap), built for one render of Flow's own graph, and its
// column order is "running agent first" for THAT screen's UX; `headerMetrics`'s `canStart` chips
// need the app's plain `KSortDescriptor.default` order instead, with no run-state preference —
// routing the header strip's summary stats through a full Flow layout rebuild per project render
// would both change that visible order and do far more work than a handful of waits-on lookups.
// The one place they are allowed to disagree: a cyclic waits-on chain. FlowLayout defensively
// pins a cycle to depth 0 so it is never lost from the layout (plan section E2); `canStart` has
// no such defense and correctly reports a cyclic task as NOT able to start. The store's own
// waits-on picker refuses to create a cycle — only external data (e.g. JSON import) can produce
// one — so this divergence is intentionally untested.
import Foundation

public enum ProjectInsights {

    /// True when `task` is itself open AND waits on nothing in `tasks` that is itself still open
    /// (a waited-on id absent from `tasks`, or present but closed, never blocks — matching
    /// `RunStore`/`ScopeFilter`'s own "closed never blocks" rule). A closed task is never a
    /// "can start" candidate.
    public static func canStart(_ task: KTask, in tasks: [KTask]) -> Bool {
        guard KStatus.open.contains(task.status) else { return false }
        let waits = task.waitsOn
        guard !waits.isEmpty else { return true }
        let byID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        return !waits.contains { id in
            guard let blocker = byID[id] else { return false }
            return KStatus.open.contains(blocker.status)
        }
    }

    /// Every task in `tasks` that can start right now (depth 0), unsorted.
    public static func canStartTasks(in tasks: [KTask]) -> [KTask] {
        tasks.filter { canStart($0, in: tasks) }
    }

    /// How many OPEN tasks in `tasks` name `taskID` in their own `waitsOn`.
    public static func openDependentsCount(of taskID: UUID, in tasks: [KTask]) -> Int {
        tasks.reduce(into: 0) { count, t in
            guard KStatus.open.contains(t.status), t.waitsOn.contains(taskID) else { return }
            count += 1
        }
    }

    /// A "gate" (plan section F): two or more open tasks wait on it directly. Shown with a flag
    /// glyph in Flow (slice E) and in the header strip below.
    public static func isGate(_ task: KTask, in tasks: [KTask]) -> Bool {
        openDependentsCount(of: task.id, in: tasks) >= 2
    }

    /// The project header strip's one line (F1): progress, up to `canStartLimit` unblocked
    /// titles (default app order), how many open tasks are blocked, how many are awaiting the
    /// person's review, and the nearest open deadline. `tasks` is one scope's own top-level tasks
    /// (every status, so progress and the dependency graph both read the whole picture).
    public struct HeaderMetrics: Equatable {
        public let doneCount: Int
        /// Every live task except canceled ones (canceled is neither "done" nor remaining work).
        public let totalCount: Int
        /// Depth-0 open tasks, in the app's default order, capped to `canStartLimit`.
        public let canStart: [KTask]
        /// Open tasks that are NOT depth 0 (they wait on something still open).
        public let blockedCount: Int
        public let readyForReviewCount: Int
        public let nearestDueDay: Int?

        public static func == (a: HeaderMetrics, b: HeaderMetrics) -> Bool {
            a.doneCount == b.doneCount && a.totalCount == b.totalCount
                && a.canStart.map(\.id) == b.canStart.map(\.id) && a.blockedCount == b.blockedCount
                && a.readyForReviewCount == b.readyForReviewCount && a.nearestDueDay == b.nearestDueDay
        }
    }

    public static func headerMetrics(tasks: [KTask], today: Int, canStartLimit: Int = 3) -> HeaderMetrics {
        let live = tasks.filter { $0.status != .canceled }
        let doneCount = live.filter { $0.status == .done }.count
        let openCount = live.filter { KStatus.open.contains($0.status) }.count
        // The full (unfiltered) `tasks` is the lookup universe, so a blocker's real status always
        // resolves correctly regardless of which other filtering a caller already applied.
        let starters = KTaskSorter.sorted(canStartTasks(in: tasks), by: KSortDescriptor.default)
        let readyForReviewCount = live.filter { $0.reviewRaw == ReviewState.awaitingCheck }.count
        let nearestDueDay = live.filter { KStatus.open.contains($0.status) }.compactMap(\.effectiveDue).min()
        return HeaderMetrics(doneCount: doneCount, totalCount: live.count,
                             canStart: Array(starters.prefix(canStartLimit)),
                             blockedCount: openCount - starters.count,
                             readyForReviewCount: readyForReviewCount, nearestDueDay: nearestDueDay)
    }
}
