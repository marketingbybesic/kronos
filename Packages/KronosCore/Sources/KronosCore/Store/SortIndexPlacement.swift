// Manual order is a fractional `sortIndex`: a row dropped between two others takes the mean of
// their indices, so a move rewrites one row. Repeated drops into the same gap halve it each
// time, and after about forty halvings the mean equals one of the neighbours: the row then sorts
// on the tie-break instead of where it was dropped.
//
// When a gap runs out, the fix is local: the moved row and its two direct neighbours are
// spread evenly between the next rows out, so a move never rewrites more than three rows. A
// whole-list renumbering would rewrite every row, which on a synced store means every row
// changing on every device at once (and conflicting with whatever the other device reordered).
// The spreading runs only as part of the move, so only the device that made the move writes.

import Foundation

public enum NeighbourPlacement {

    public struct Plan: Equatable, Sendable {
        /// The moving row's new index.
        public var index: Double
        /// Other rows that must change so the moving row fits (empty in the normal case).
        public var neighbours: [UUID: Double]

        public init(index: Double, neighbours: [UUID: Double] = [:]) {
            self.index = index
            self.neighbours = neighbours
        }
    }

    /// The default step between rows and at either end of a list.
    public static let step: Double = 1024

    /// True when a value strictly between `lo` and `hi` keeps a usable distance to both (a
    /// relative margin, so large and small indices behave the same).
    public static func hasRoom(_ lo: Double, _ hi: Double) -> Bool {
        guard hi > lo else { return false }
        let scale = max(abs(lo), abs(hi), 1)
        return (hi - lo) > scale * 0x1p-30
    }

    /// Where a row lands when inserted before `rows[slot]` (`slot == rows.count`: at the end).
    /// `rows` is the destination in display order WITHOUT the moving row.
    public static func plan(rows: [(id: UUID, idx: Double)], slot rawSlot: Int) -> Plan {
        let n = rows.count
        let slot = min(max(rawSlot, 0), n)
        let lo = slot > 0 ? rows[slot - 1].idx : nil
        let hi = slot < n ? rows[slot].idx : nil
        switch (lo, hi) {
        case (nil, nil): return Plan(index: 0)
        case let (nil, hi?): return Plan(index: hi - step)
        case let (lo?, nil): return Plan(index: lo + step)
        case let (lo?, hi?):
            if hasRoom(lo, hi) { return Plan(index: (lo + hi) / 2) }
            return spread(rows: rows, slot: slot)
        }
    }

    /// Rewrite the `k` rows on each side of the slot (k = 1: the two direct neighbours) evenly
    /// between the next rows out, widening only when even that window has no room left.
    static func spread(rows: [(id: UUID, idx: Double)], slot: Int) -> Plan {
        let n = rows.count
        var k = 1
        while true {
            let first = max(slot - k, 0), last = min(slot + k - 1, n - 1)
            let window = Array(rows[first...last])
            let lowValues = window.map(\.idx)
            let lower = first > 0 ? rows[first - 1].idx : (lowValues.min() ?? 0) - step * Double(k + 1)
            let upper = last < n - 1 ? rows[last + 1].idx : (lowValues.max() ?? 0) + step * Double(k + 1)
            // window rows + the moving row, evenly spaced strictly inside (lower, upper)
            let count = window.count + 1
            let gap = (upper - lower) / Double(count + 1)
            let covered = first == 0 && last == n - 1
            if hasRoom(lower, lower + gap) || covered {
                var plan = Plan(index: 0)
                var position = 1
                for (i, row) in rows.enumerated() where i >= first && i <= last {
                    if i == slot { plan.index = lower + gap * Double(position); position += 1 }
                    plan.neighbours[row.id] = lower + gap * Double(position)
                    position += 1
                }
                if slot > last { plan.index = lower + gap * Double(position) }
                return plan
            }
            k += 1
        }
    }
}

@MainActor
extension TaskStore {

    /// The landing plan for `moving` directly before `target` (nil or unknown: the end) in
    /// `rows`, given in display order. The moving row is ignored wherever it appears in `rows`.
    func placement(for moving: UUID, before target: UUID?,
                   in rows: [(id: UUID, idx: Double)]) -> NeighbourPlacement.Plan {
        let others = rows.filter { $0.id != moving }
        let slot = target.flatMap { t in others.firstIndex { $0.id == t } } ?? others.count
        return NeighbourPlacement.plan(rows: others, slot: slot)
    }

    /// Move top-level task `id` directly before `before` (nil: the end) of `order`, the manual
    /// order of the list being shown. Rewrites the task and, only when the gap is used up, its
    /// two direct neighbours. False (nothing pushed) when the task is missing, `before` is not
    /// in `order`, or the task already sits there. REGISTERS UNDO (one step).
    @discardableResult
    public func moveTask(_ id: UUID, before: UUID?, inOrder order: [UUID]) -> Bool {
        guard let moving = task(id) else { return false }
        if let before, before == id || !order.contains(before) { return false }
        let others = order.filter { $0 != id }
        if let i = order.firstIndex(of: id) {
            let next = i + 1 < order.count ? order[i + 1] : nil
            if next == before { return false }
        }
        // One fetch for the whole list, not one per row.
        let byID = Dictionary(allTasks().map { ($0.id, $0.sortIndex) }, uniquingKeysWith: { a, _ in a })
        let rows = others.compactMap { oid in byID[oid].map { (id: oid, idx: $0) } }
        let plan = placement(for: id, before: before, in: rows)
        guard plan.index != moving.sortIndex || !plan.neighbours.isEmpty else { return false }
        groupedUndo("Reorder") {
            for (nid, idx) in plan.neighbours.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                update(nid) { $0.sortIndex = idx }
            }
            update(id) { $0.sortIndex = plan.index }
        }
        return true
    }
}
