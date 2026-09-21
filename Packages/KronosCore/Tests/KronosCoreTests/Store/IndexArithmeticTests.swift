import Testing
import Foundation
@testable import KronosCore

/// `appendIndex`/`pushTopIndex` used to compute the next `.tasksGlobal`/`.ordo` index by
/// fetching every live task and taking `.max()`/`.min()` of an in-memory array
/// (`scopeIndices`) — an O(n) fetch-and-decode on every single task create or Ordo reorder.
/// `taskExtremeSortIndex`/`taskExtremeOrdoIndex` (TaskStore+Lookups.swift) replace that with a
/// sorted `FetchDescriptor` and `fetchLimit = 1`. These tests pin the exact behaviour the old
/// array-based code had, hand-computed against a known set of tasks — not derived from the
/// same code path being tested — so a regression in the fetch predicate or sort order shows up
/// as a wrong number, not a passing tautology.
@MainActor
struct IndexArithmeticTests {
    @Test func appendIndexOnEmptyStoreMatchesOldEmptyArrayBehaviour() throws {
        let store = try TaskStore(inMemory: true)
        // Old: (([Double]().max()) ?? -1024) + 1024 == 0
        #expect(store.create(title: "First").sortIndex == 0)
    }

    @Test func appendIndexAfterNRowsIsStrictlyIncreasing() throws {
        let store = try TaskStore(inMemory: true)
        var last = -Double.infinity
        for i in 0..<20 {
            let t = store.create(title: "Task \(i)")
            #expect(t.sortIndex > last)
            last = t.sortIndex
        }
    }

    @Test func softDeletedTopRowIsExcludedFromTheMax() throws {
        let store = try TaskStore(inMemory: true)
        let a = store.create(title: "A")
        let b = store.create(title: "B")
        #expect(b.sortIndex > a.sortIndex)
        // Soft-delete the current top row: the next append must skip it, exactly like
        // `allTasks()` (which livePredicate already excludes deletedAt != nil rows from) did.
        store.softDelete(b.id)
        let c = store.create(title: "C")
        #expect(c.sortIndex > a.sortIndex)
        // b is soft-deleted, so its slot is free to be reused — c lands exactly where b did
        // (a.sortIndex + 1024), proving the max computation skipped the deleted row rather than
        // continuing to grow past it.
        #expect(c.sortIndex == b.sortIndex, "a soft-deleted row must not still count as the max")
    }

    @Test func ordoAppendAndPushTopMatchHandComputedValues() throws {
        let store = try TaskStore(inMemory: true)
        let t1 = store.create(title: "One")
        let t2 = store.create(title: "Two")
        let t3 = store.create(title: "Three")

        // Empty Ordo: append is the "no rows" case (-1024 + 1024 == 0), same as tasksGlobal.
        store.sendToOrdo(t1.id)
        #expect(store.task(t1.id)?.ordoIndex == 0)

        // Second append goes after the first (t1.ordoIndex + 1024).
        store.sendToOrdo(t2.id)
        let idx2 = store.task(t2.id)?.ordoIndex
        #expect(idx2 == 1024)

        // pushTopIndex goes before the current min (t1.ordoIndex - 1024).
        store.sendToOrdo(t3.id, top: true)
        let idx3 = store.task(t3.id)?.ordoIndex
        #expect(idx3 == -1024)

        // Ordering by ordoIndex is now t3, t1, t2.
        let ordoOrder = [t3.id, t1.id, t2.id].map { store.task($0)?.ordoIndex }
        #expect(ordoOrder == ordoOrder.sorted { ($0 ?? 0) < ($1 ?? 0) })
    }

    @Test func ordoScopeIsIsolatedFromSortIndexScope() throws {
        // A task's sortIndex (tasksGlobal scope) and ordoIndex (ordo scope) are independent
        // sequences: three plain creates advance tasksGlobal's max three times, all while Ordo
        // stays empty, then sending ONE of them to Ordo must land at Ordo's "empty scope" value
        // (0), not continue tasksGlobal's own running sequence.
        let store = try TaskStore(inMemory: true)
        let t1 = store.create(title: "One")
        let t2 = store.create(title: "Two")
        let t3 = store.create(title: "Three")
        #expect(t1.sortIndex == 0)
        #expect(t2.sortIndex == 1024)
        #expect(t3.sortIndex == 2048)

        store.sendToOrdo(t2.id)
        // Ordo was empty until now: its append value is Ordo's own "no rows" case (0), not
        // t3.sortIndex + 1024 (2048 + 1024) — proving the two scopes never share a sequence.
        #expect(store.task(t2.id)?.ordoIndex == 0)
    }

    @Test func fetchCountsShowOneFetchPerAppendNotOneFetchPerExistingRow() throws {
        // The regression this leaf exists to prevent: appendIndex must stay a single sorted
        // fetch regardless of how many tasks already exist, not scale with table size.
        let store = try TaskStore(inMemory: true)
        for i in 0..<50 { _ = store.createNoUndo(title: "Task \(i)") }
        store.resetFetchCounts()
        _ = store.createNoUndo(title: "Task 50")
        // create() -> appendIndex(.tasksGlobal) -> exactly one taskExtremeSortIndex fetch.
        #expect(store.fetchCounts.byReason["taskExtremeSortIndex(max:)"] == 1)
    }
}
