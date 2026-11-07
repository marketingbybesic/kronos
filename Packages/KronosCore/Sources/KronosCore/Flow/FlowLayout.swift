// Flow is a to-do-native dependency graph view (columns by dependency depth: can-start / next /
// later). FlowLayout is its pure engine: given an already scope-filtered task list (the caller
// decides which tasks are in scope — FlowLayout never does project/area/date filtering itself),
// it assigns each task a column depth, orders cards within a column, draws the dependency edge
// list, defends against cyclic waits-on data (which CAN occur: it arrives from JSON import,
// which does not run the same cycle guard the UI picker does), and applies a card-count cap.

import Foundation

/// Pure dependency-depth layout for the Flow view. No stored state, no I/O, no logging, no
/// mutation of its input — a namespace of static functions only.
public enum FlowLayout {

    /// One dependency arrow: `to` waits on `from` (from = prerequisite, to = dependent).
    public struct Edge: Hashable, Sendable {
        public let from: UUID
        public let to: UUID
        /// Swift does not synthesize a `public` memberwise init for a `public` struct (only
        /// `internal`), so callers outside this module (the UI layer, which constructs an
        /// `Edge` to track the one just crossed by a Flow ←/→ key press) need this explicit one.
        public init(from: UUID, to: UUID) {
            self.from = from
            self.to = to
        }
    }

    /// One dependency-depth column. Only depths that actually hold a card exist in
    /// `Result.columns` — never an empty placeholder.
    public struct Column: Identifiable, Sendable {
        public var id: Int { depth }
        public let depth: Int
        /// Already fully sorted (see Ordering below).
        public let taskIDs: [UUID]
    }

    public struct Result: Sendable {
        /// Ascending by depth; see Column's own doc for the "only non-empty" rule.
        public let columns: [Column]
        /// Only edges where BOTH endpoints are visible task ids in `columns` (so capping or
        /// cycle defense never produces a dangling edge a caller would try to draw to a card
        /// that does not exist).
        public let edges: [Edge]
        /// nil when `tasks.count` did not exceed `cap`. Otherwise the PRE-cap total task count
        /// (tasks.count), so a caller can show "Show all (N)".
        public let cappedTotal: Int?
        /// Task ids that were defensively pinned to depth 0 because following their open
        /// waits-on chain would otherwise cycle. Never causes compute to loop or crash.
        public let cycles: [UUID]
    }

    /// Pure — no I/O, no logging, no mutation of `tasks`. `tasks` is the caller's own already
    /// scope-filtered set (open tasks in scope, plus done tasks completed today, in scope —
    /// deciding "in scope" is the caller's job, not this function's). `activeRun` resolves a
    /// task id to its currently-running run if any (typically `RunStore.activeRun(taskID:)`
    /// wrapped in a closure by the caller) — used only for the "running sorts first" rule
    /// below, nothing else. `today` is `Day.today()`. `cap` is the total-card-count ceiling
    /// (E6 of the plan): nil disables capping entirely (used when the UI's "Show all" button
    /// was pressed); the default of 150 matches the shipped behavior.
    public static func build(tasks: [KTask], activeRun: (UUID) -> KAgentRun?,
                              today: Int, cap: Int? = 150) -> Result {
        var tasksByID: [UUID: KTask] = [:]
        tasksByID.reserveCapacity(tasks.count)
        for t in tasks { tasksByID[t.id] = t }

        func openPrereqs(_ t: KTask) -> [UUID] {
            t.waitsOn.filter { pid in
                guard let p = tasksByID[pid] else { return false }
                return KStatus.open.contains(p.status)
            }
        }

        // DFS with memoization and an explicit "currently being resolved" path. A back-edge
        // (a prerequisite already on the active path) pins every id from the ancestor onward —
        // the actual cycle, not anything merely downstream of it — to depth 0 and records each
        // newly-pinned id once in `cycles`. This terminates on any cycle length because every
        // node is visited at most once per path position and memoized afterward.
        var depths: [UUID: Int] = [:]
        var forcedZero: Set<UUID> = []
        var cycles: [UUID] = []
        var path: [UUID] = []
        var onPath: Set<UUID> = []

        func resolveDepth(_ id: UUID) -> Int {
            if let cached = depths[id] { return cached }
            guard let t = tasksByID[id] else { return 0 }
            if !KStatus.open.contains(t.status) {
                depths[id] = 0
                return 0
            }
            path.append(id)
            onPath.insert(id)
            var maxPrereq = -1
            for p in openPrereqs(t) {
                if onPath.contains(p) {
                    if let ancestorIdx = path.firstIndex(of: p) {
                        for cid in path[ancestorIdx...] where forcedZero.insert(cid).inserted {
                            cycles.append(cid)
                        }
                    }
                    continue
                }
                let pd = resolveDepth(p)
                if pd > maxPrereq { maxPrereq = pd }
            }
            path.removeLast()
            onPath.remove(id)
            let d = forcedZero.contains(id) ? 0 : (maxPrereq < 0 ? 0 : maxPrereq + 1)
            depths[id] = d
            return d
        }

        for t in tasks { _ = resolveDepth(t.id) }

        var edges: [Edge] = []
        for t in tasks {
            guard KStatus.open.contains(t.status), !forcedZero.contains(t.id) else { continue }
            for p in openPrereqs(t) where !forcedZero.contains(p) {
                edges.append(Edge(from: p, to: t.id))
            }
        }

        struct SortKey {
            let running: Bool
            let ordo: Double
            let due: Int
            let idString: String
        }
        var sortKeys: [UUID: SortKey] = [:]
        sortKeys.reserveCapacity(tasks.count)
        for t in tasks {
            sortKeys[t.id] = SortKey(running: activeRun(t.id) != nil,
                                      ordo: t.ordoIndex ?? .greatestFiniteMagnitude,
                                      due: t.effectiveDue ?? .max,
                                      idString: t.id.uuidString)
        }

        var byDepth: [Int: [UUID]] = [:]
        for t in tasks { byDepth[depths[t.id] ?? 0, default: []].append(t.id) }

        var columns = byDepth.keys.sorted().map { depth -> Column in
            let ordered = byDepth[depth]!.map { ($0, sortKeys[$0]!) }.sorted { a, b in
                if a.1.running != b.1.running { return a.1.running }
                if a.1.ordo != b.1.ordo { return a.1.ordo < b.1.ordo }
                if a.1.due != b.1.due { return a.1.due < b.1.due }
                return a.1.idString < b.1.idString
            }
            return Column(depth: depth, taskIDs: ordered.map(\.0))
        }

        let total = tasks.count
        var cappedTotal: Int? = nil
        if let cap, total > cap {
            cappedTotal = total
            columns = columns.filter { $0.depth <= 1 }
        }

        let visible = Set(columns.flatMap(\.taskIDs))
        edges = edges.filter { visible.contains($0.from) && visible.contains($0.to) }

        return Result(columns: columns, edges: edges, cappedTotal: cappedTotal, cycles: cycles)
    }

    /// Every id (restricted to endpoints present in `edges`) that `id` transitively waits on —
    /// "blocked by". Empty set when `id` has no incoming chain in `edges`.
    public static func upstream(of id: UUID, edges: [Edge]) -> Set<UUID> {
        var result: Set<UUID> = []
        var visited: Set<UUID> = [id]
        var frontier: [UUID] = [id]
        while let current = frontier.popLast() {
            for e in edges where e.to == current {
                if visited.insert(e.from).inserted {
                    result.insert(e.from)
                    frontier.append(e.from)
                }
            }
        }
        return result
    }

    /// Every id (restricted to endpoints present in `edges`) that transitively waits on `id` —
    /// "unblocks". Empty set when nothing depends on `id` in `edges`.
    public static func downstream(of id: UUID, edges: [Edge]) -> Set<UUID> {
        var result: Set<UUID> = []
        var visited: Set<UUID> = [id]
        var frontier: [UUID] = [id]
        while let current = frontier.popLast() {
            for e in edges where e.from == current {
                if visited.insert(e.to).inserted {
                    result.insert(e.to)
                    frontier.append(e.to)
                }
            }
        }
        return result
    }
}
