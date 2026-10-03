// KronosCore/Drop/DropPlacement.swift
// The arithmetic of "land directly before this task" in a manually ordered list: which two
// sortIndex values the new slot sits between and what value goes there. Pure, so the table in
// DropPlacementTests can pin it without a store.
import Foundation

public enum DropPlacement {
    /// The sortIndex neighbours of the slot directly before `before` (nil: at the end) in `order`
    /// (task ids in manual order), ignoring `excluding`. `lo` / `hi` are nil at the start / at the end
    /// of the list. Returns nil when `before` is not in the list.
    public static func slot(before: UUID?, order: [UUID], excluding: UUID?,
                            sortIndex: (UUID) -> Double?) -> (lo: Double?, hi: Double?)? {
        let others = order.filter { $0 != excluding }
        guard let before else { return (others.last.flatMap(sortIndex), nil) }
        guard let i = others.firstIndex(of: before), let hi = sortIndex(before) else { return nil }
        return (i == 0 ? nil : sortIndex(others[i - 1]), hi)
    }

    /// The value for a row between `lo` and `hi`: their mean, a step past the single neighbour, or 0
    /// when the list is empty.
    public static func indexBetween(lo: Double?, hi: Double?) -> Double {
        switch (lo, hi) {
        case let (lo?, hi?): return (lo + hi) / 2
        case let (nil, hi?): return hi - 1024
        case let (lo?, nil): return lo + 1024
        case (nil, nil): return 0
        }
    }

    /// True when `moving` already sits directly before `before` (nil: already last), so a drop
    /// there changes nothing and must push no undo step.
    public static func isNoOp(moving: UUID, before: UUID?, order: [UUID]) -> Bool {
        if before == moving { return true }
        guard let i = order.firstIndex(of: moving) else { return false }
        let next = i + 1 < order.count ? order[i + 1] : nil
        return next == before
    }
}
