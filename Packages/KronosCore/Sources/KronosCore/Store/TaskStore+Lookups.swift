// Packages/KronosCore/Sources/KronosCore/Store/TaskStore+Lookups.swift
//
// `task(_:)` was `allTasks().first { $0.id == id }` (a full-table fetch per lookup) called
// from dozens of UI and MCP sites — selecting a row, opening the inspector, every MCP tool
// that takes a task id. At scale (thousands of tasks) that is a fetch-and-decode of the whole
// table just to find one row. Fetching by predicate with `fetchLimit = 1` lets SwiftData stop
// at the first match instead.
//
// `TaskStore.swift` is already at the 500-line file cap, so this extension (lookups/fetch
// counting only — no status-rule logic, which stays in the main file) lives here instead of
// growing it further.

import Foundation
import SwiftData

@MainActor
extension TaskStore {
    /// Debug-only: how many times a fetch actually ran against the persistent store this
    /// session, broken down by call site. Zero cost in a release build in the sense that
    /// nothing reads it outside a test — but the counter itself always increments (its own
    /// overhead is a dictionary bump, not worth an `#if DEBUG` seam) so a test can assert
    /// real fetch counts (e.g. "typing one character re-fetched zero times") without any
    /// separate instrumented build.
    public struct FetchCounts {
        public internal(set) var byReason: [String: Int] = [:]
        public var total: Int { byReason.values.reduce(0, +) }
    }

    private static var counters: [ObjectIdentifier: FetchCounts] = [:]

    public var fetchCounts: FetchCounts {
        get { Self.counters[ObjectIdentifier(self)] ?? FetchCounts() }
        set { Self.counters[ObjectIdentifier(self)] = newValue }
    }

    public func resetFetchCounts() { fetchCounts = FetchCounts() }

    func countFetch(_ reason: String) {
        fetchCounts.byReason[reason, default: 0] += 1
    }

    /// One live task by id — `fetchLimit = 1` stops SwiftData at the first match instead of
    /// materializing every row (`task(_:)`'s old body: `allTasks().first { $0.id == id }`).
    public func task(_ id: UUID) -> KTask? {
        countFetch("task(_:)")
        var d = FetchDescriptor<KTask>(predicate: #Predicate<KTask> { $0.id == id && $0.deletedAt == nil })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first
    }

    /// Inclusive of soft-deleted rows — same `fetchLimit = 1` shape as `task(_:)`.
    public func taskIncludingDeleted(_ id: UUID) -> KTask? {
        countFetch("taskIncludingDeleted(_:)")
        var d = FetchDescriptor<KTask>(predicate: #Predicate<KTask> { $0.id == id })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first
    }

    /// The max (or min) `sortIndex` among LIVE tasks — same value
    /// `scopeIndices(.tasksGlobal).max()`/`.min()` computed, but via a sorted fetch with
    /// `fetchLimit = 1` instead of decoding every row to find the extreme. `nil` when the
    /// scope is empty, matching `[Double]().max()`/`.min()`.
    func taskExtremeSortIndex(max: Bool) -> Double? {
        countFetch("taskExtremeSortIndex(max:)")
        var d = FetchDescriptor<KTask>(predicate: livePredicate,
                                       sortBy: [SortDescriptor(\.sortIndex, order: max ? .reverse : .forward)])
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first?.sortIndex
    }

    /// The max (or min) `ordoIndex` among LIVE tasks that HAVE one — same value
    /// `scopeIndices(.ordo).max()`/`.min()` computed (`allTasks().compactMap(\.ordoIndex)`),
    /// via a sorted fetch with `fetchLimit = 1`. `nil` when no live task has an `ordoIndex`,
    /// matching `[Double]().max()`/`.min()`.
    func taskExtremeOrdoIndex(max: Bool) -> Double? {
        countFetch("taskExtremeOrdoIndex(max:)")
        var d = FetchDescriptor<KTask>(predicate: #Predicate<KTask> { $0.deletedAt == nil && $0.ordoIndex != nil },
                                       sortBy: [SortDescriptor(\.ordoIndex, order: max ? .reverse : .forward)])
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first?.ordoIndex
    }
}
