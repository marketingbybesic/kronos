import Foundation
import Testing
@testable import KronosCore

/// Opt-in: KRONOS_STORE_DIR=<dir holding a COPY of a real Kronos.store> swift test --filter LiveMigrationTests
/// Opens the copy with today's schema (SwiftData lightweight migration) and prints the counts.
/// Never runs in the normal suite and never touches the real store.
@MainActor
@Suite struct LiveMigrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KRONOS_STORE_DIR"] != nil))
    func copiedStoreOpensUnderTheCurrentSchema() throws {
        let store = try TaskStore()
        let tasks = store.allTasks()
        let projects = store.allProjects(includeArchived: true)
        print("live migration: tasks=\(tasks.count) projects=\(projects.count) areas=\(store.allAreas().count)")
        #expect(!projects.isEmpty || !tasks.isEmpty, "the copied store opened but is empty")
        for p in projects { _ = p.icon; _ = p.colorHex }
        for t in tasks { _ = t.effort; _ = t.firstMove }
    }

    /// Same opt-in mechanism, but runs the real one-time migration against the copy and
    /// prints a machine-parseable line a verification script greps for. Never touches the
    /// real store — `KRONOS_STORE_DIR` must already point at a COPY (made via `cp`, never
    /// opened by anything before this test runs).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KRONOS_STORE_DIR"] != nil))
    func migrateCopyOnceAndPrintCounts() throws {
        let store = try TaskStore()
        let before = store.allTasks().filter { $0.status == .todo && $0.dueDay == nil }.count
        let result = UndatedSomedayMigration.runIfNeeded(store: store)
        let moved = result?.moved ?? 0
        let remaining = store.allTasks().filter { $0.status == .todo && $0.dueDay == nil }.count
        print("MIGRATE COPY TEST before=\(before) moved=\(moved) remainingUndatedTodo=\(remaining)")
        #expect(remaining == 0, "every open undated todo must have moved to Someday")
    }
}
