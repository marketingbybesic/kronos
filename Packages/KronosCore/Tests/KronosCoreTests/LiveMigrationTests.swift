import Foundation
import SwiftData
import Testing
@testable import KronosCore

/// Opt-in runs on a COPY of a real store. `KRONOS_STORE_DIR` must point at a folder holding a
/// copy (made by `scripts/verify-subtask-migration-copy.mjs`, never the real Application Support
/// folder). Never runs in the normal suite.
@MainActor
@Suite struct LiveMigrationTests {
    nonisolated static var hasCopy: Bool {
        let dir = ProcessInfo.processInfo.environment["KRONOS_STORE_DIR"] ?? ""
        return !dir.isEmpty && !dir.contains("Library/Application Support")
    }
    nonisolated static var wantsExport: Bool {
        hasCopy && !(ProcessInfo.processInfo.environment["KRONOS_MIGCHK_EXPORT"] ?? "").isEmpty
    }

    @Test(.enabled(if: LiveMigrationTests.hasCopy && !LiveMigrationTests.wantsExport))
    func copiedStoreOpensUnderTheCurrentSchema() throws {
        let store = try TaskStore()
        let tasks = store.allTasks()
        let projects = store.allProjects(includeArchived: true)
        print("live migration: tasks=\(tasks.count) projects=\(projects.count) areas=\(store.allAreas().count)")
        #expect(!projects.isEmpty || !tasks.isEmpty, "the copied store opened but is empty")
    }

    /// Runs the undated-task launch migration against the copy and prints the line
    /// the internal check script parses.
    @Test(.enabled(if: LiveMigrationTests.hasCopy && !LiveMigrationTests.wantsExport))
    func migrateCopyOnceAndPrintCounts() throws {
        let store = try TaskStore()
        let before = store.allTasks().filter { $0.status == .todo && $0.dueDay == nil }.count
        let result = UndatedSomedayMigration.runIfNeeded(store: store)
        let moved = result?.moved ?? 0
        let remaining = store.allTasks().filter { $0.status == .todo && $0.dueDay == nil }.count
        print("MIGRATE COPY TEST before=\(before) moved=\(moved) remainingUndatedTodo=\(remaining)")
    }

    /// The launch sequence the app runs (safety copy, open with the migration plan, marker), then
    /// the JSON export written to `KRONOS_MIGCHK_EXPORT`. Prints one line the script parses.
    @Test(.enabled(if: LiveMigrationTests.wantsExport))
    func launchSequenceThenExport() throws {
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KRONOS_MIGCHK_EXPORT"]!)
        let storeURL = KronosStore.storeURL()
        let wasV2 = SchemaV2Upgrade.storeIsV2(at: storeURL)
        print("MIGCHK SHAPE olderThanV1=\(SchemaV0Test.matches(storeURL)) "
              + "v1=\(String(describing: SchemaV2Upgrade.storeIsV1(at: storeURL))) v2=\(String(describing: wasV2))")
        let backup = SubtaskToTaskMigration.backupStoreFilesIfNeeded()
        let store = try TaskStore()
        let converted = SubtaskToTaskMigration.runIfNeeded(store: store, backup: backup)
        let data = JSONExporter(store: store).exportData(now: Date(timeIntervalSince1970: 0))
        try data.write(to: out)
        var copy = "none"
        if case .made(let dir) = backup { copy = dir.lastPathComponent }
        print("MIGCHK POST wasV2=\(String(describing: wasV2)) isV2=\(String(describing: SchemaV2Upgrade.storeIsV2(at: storeURL))) "
              + "backup=\(copy) converted=\(converted.map { "\($0.converted)/\($0.orphans)/\($0.alreadyTasks)" } ?? "nil") "
              + "tasks=\(store.allTasksIncludingDeleted().count) bytes=\(data.count)")
        #expect(SchemaV2Upgrade.storeIsV2(at: storeURL) == true)
        #expect(!data.isEmpty)

        // After the export: the upgraded copy takes a write with V2 fields (then it is removed).
        let probe = store.createNoUndo(title: "copy check probe")
        store.updateNoUndo(probe.id) { $0.plannedDay = 20_003; $0.lockedFieldsRaw = "priority" }
        try store.context.save()
        let reread = try TaskStore()
        #expect(reread.taskIncludingDeleted(probe.id)?.plannedDay == 20_003)
        print("MIGCHK WRITE after upgrade ok=\(reread.taskIncludingDeleted(probe.id)?.plannedDay == 20_003)")
        if let row = reread.taskIncludingDeleted(probe.id) {
            reread.context.delete(row)
            try reread.context.save()
        }
    }
}
