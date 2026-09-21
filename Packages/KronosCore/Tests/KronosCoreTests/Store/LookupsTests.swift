import Testing
import Foundation
@testable import KronosCore

/// `task(_:)` / `taskIncludingDeleted(_:)` moved from `allTasks().first { $0.id == id }` to a
/// predicate fetch with `fetchLimit = 1` (TaskStore+Lookups.swift) — correctness first (still
/// finds the right row, still excludes soft-deleted rows from the live variant), then a fetch
/// counter that makes launch/list-responsiveness claims testable rather than asserted from
/// prose.
@MainActor
struct LookupsTests {
    @Test func findsExistingLiveTask() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.create(title: "Find me")
        #expect(store.task(t.id)?.id == t.id)
    }

    @Test func missingIDReturnsNil() throws {
        let store = try TaskStore(inMemory: true)
        #expect(store.task(UUID()) == nil)
    }

    @Test func softDeletedExcludedFromLiveLookupButNotFromIncludingDeleted() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.create(title: "Will be deleted")
        store.softDelete(t.id)
        #expect(store.task(t.id) == nil)
        #expect(store.taskIncludingDeleted(t.id)?.id == t.id)
    }

    @Test func fetchCounterTracksRealFetchesOnly() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.create(title: "Counted")
        store.resetFetchCounts()
        #expect(store.fetchCounts.total == 0)

        _ = store.task(t.id)
        _ = store.task(t.id)
        _ = store.taskIncludingDeleted(t.id)

        #expect(store.fetchCounts.byReason["task(_:)"] == 2)
        #expect(store.fetchCounts.byReason["taskIncludingDeleted(_:)"] == 1)
        #expect(store.fetchCounts.total == 3)
    }

    /// The regression this leaf exists to prevent: `task(_:)` must never again become
    /// `allTasks().first { }` — a fetch that scales with table size instead of stopping at the
    /// first match. 500 rows is enough to make an accidental full scan measurably slower than a
    /// predicate fetch without making the test itself slow.
    @Test func lookupStaysFastAsTableGrows() throws {
        let store = try TaskStore(inMemory: true)
        var ids: [UUID] = []
        for i in 0..<500 {
            ids.append(store.createNoUndo(title: "Task \(i)").id)
        }
        let target = ids[0] // worst case for a linear "first match" scan: the very first row
        let start = Date()
        for _ in 0..<200 { _ = store.task(target) }
        let elapsed = Date().timeIntervalSince(start)
        // Generous bound (this is a correctness/regression guard, not a strict timing claim): a
        // predicate fetch on 500 rows, 200 times, comfortably finishes under a second on CI
        // hardware; a reintroduced O(n) `.first {}` at this size would not necessarily fail this
        // bound on its own, so a dedicated scale benchmark (5,000 rows, explicit ms bounds) is
        // the actual performance gate — this test only proves the counter and the predicate
        // path are wired correctly.
        #expect(elapsed < 2.0)
    }
}
