import Foundation
import Testing
@testable import KronosCore

/// The automatic status rule (`TaskStore+Setters.swift:34-47`, doc comment at
/// TaskStore.swift:367) only fires on a due-day EDIT, so it never touches a task created
/// before the rule existed. This is the one-time catch-up migration for exactly that case:
/// an open `.todo` task with no due day that predates the rule.
@MainActor
@Suite struct UndatedSomedayMigrationTests {

    /// Builds a representative pre-migration shape: 35 todo/undated (should move), 20
    /// todo/dated (must stay), 1 waiting/dated (must stay), 3 someday/undated (already
    /// correct, must stay), plus one each of inProgress/undated, completed/undated,
    /// deleted/undated — none of which may move.
    private func makeRealisticStore() throws -> TaskStore {
        let store = try TaskStore(inMemory: true)
        for i in 0..<35 {
            store.createNoUndo(title: "Undated todo \(i)", status: .todo, dueDay: nil)
        }
        for i in 0..<20 {
            store.createNoUndo(title: "Dated todo \(i)", status: .todo, dueDay: Day.today() + i)
        }
        store.createNoUndo(title: "Waiting dated", status: .waiting, dueDay: Day.today())
        for i in 0..<3 {
            store.createNoUndo(title: "Already someday \(i)", status: .someday, dueDay: nil)
        }
        let inProg = store.createNoUndo(title: "In progress undated", status: .todo, dueDay: nil)
        store.setStatusNoUndo(inProg.id, .inProgress)
        let done = store.createNoUndo(title: "Completed undated", status: .todo, dueDay: nil)
        store.completeNoUndo(done.id)
        let deleted = store.createNoUndo(title: "Deleted undated", status: .todo, dueDay: nil)
        store.softDeleteNoUndo(deleted.id)
        return store
    }

    @Test func movesOnlyOpenUndatedTodoToSomeday() throws {
        let store = try makeRealisticStore()
        let result = TaskStore.migrateUndatedTodoToSomeday(store: store)
        #expect(result.moved == 35)

        let all = store.allTasksIncludingDeleted()
        #expect(all.filter { $0.title.hasPrefix("Undated todo") }.allSatisfy { $0.status == .someday } == true)
        #expect(all.filter { $0.title.hasPrefix("Dated todo") }.allSatisfy { $0.status == .todo } == true)
        #expect(all.first { $0.title == "Waiting dated" }!.status == .waiting)
        #expect(all.filter { $0.title.hasPrefix("Already someday") }.allSatisfy { $0.status == .someday } == true)
        #expect(all.first { $0.title == "In progress undated" }!.status == .inProgress)
        #expect(all.first { $0.title == "Completed undated" }!.status == .done)
        #expect(all.first { $0.title == "Deleted undated" }!.status == .todo, "deleted rows are untouched, not migrated")
    }

    @Test func pushesNoUndoStep() throws {
        let store = try makeRealisticStore()
        let depthBefore = store.undoDepth
        _ = TaskStore.migrateUndatedTodoToSomeday(store: store)
        #expect(store.undoDepth == depthBefore)
    }

    @Test func secondRunChangesNothing() throws {
        let store = try makeRealisticStore()
        let first = TaskStore.migrateUndatedTodoToSomeday(store: store)
        #expect(first.moved == 35)
        let second = TaskStore.migrateUndatedTodoToSomeday(store: store)
        #expect(second.moved == 0)
    }

    @Test func emptyStoreMovesNothing() throws {
        let store = try TaskStore(inMemory: true)
        let result = TaskStore.migrateUndatedTodoToSomeday(store: store)
        #expect(result.moved == 0)
    }

    /// `BackupScheduler.prune()` (Kronos/Settings/BackupScheduler.swift:49-56) sweeps every file
    /// in the Backups folder whose name `hasPrefix("kronos-")` AND `pathExtension == "json"`,
    /// sorted by filename, keeping only the newest 14 — a name that matched would permanently
    /// occupy one of the 14 daily-backup slots (this migration's name sorts after every real
    /// "kronos-2026-..." daily name, so it would never be the one pruned) and push a real daily
    /// backup out. Hand-written copy of the pruner's own two conditions (this file cannot import
    /// app code into Core): the pre-migration backup name must NOT match.
    @Test func preMigrationBackupNameIsInvisibleToTheDailyPruner() throws {
        let dailyNames = (0..<14).map { "kronos-2026-09-\(String(format: "%02d", $0 + 1)).json" }
        let ownName = "pre-migration-undatedSomeday-v1-20260921T105753Z.json"
        let allNames = dailyNames + [ownName]

        func prunerWouldConsider(_ name: String) -> Bool {
            name.hasPrefix("kronos-") && (name as NSString).pathExtension == "json"
        }
        let matched = allNames.filter(prunerWouldConsider)
        #expect(matched.count == dailyNames.count, "the pre-migration backup must not be swept by the daily pruner")
        #expect(!matched.contains(ownName))
    }

    /// Brief-required: "backup failure -> nothing changes." Pre-creates a regular FILE named
    /// `Backups` inside the store directory, so `BackupFile.write`'s own
    /// `FileManager.createDirectory` (Export/BackupFile.swift:32) throws (a file already
    /// occupies that path) before anything is written. `runIfNeeded` must then skip the
    /// migration entirely: no task changes status, and no marker is written (so the very next
    /// launch retries rather than silently giving up forever).
    @Test func backupFailureSkipsMigrationAndWritesNoMarker() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("kronos-backup-fail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        // A plain file where the Backups DIRECTORY needs to go: BackupFile.write's own
        // `createDirectory(at:)` fails because a non-directory already occupies that path.
        FileManager.default.createFile(atPath: tempRoot.appendingPathComponent("Backups").path,
                                       contents: Data())

        setenv("KRONOS_STORE_DIR", tempRoot.path, 1)
        defer { unsetenv("KRONOS_STORE_DIR") }

        let store = try TaskStore(inMemory: true)
        store.createNoUndo(title: "Undated todo", status: .todo, dueDay: nil)

        let result = UndatedSomedayMigration.runIfNeeded(store: store)
        #expect(result == nil)
        #expect(store.allTasks().allSatisfy { $0.status == .todo }, "nothing may have moved when the backup failed")

        let marker = tempRoot.appendingPathComponent("migrations/undatedSomeday.v1")
        #expect(!FileManager.default.fileExists(atPath: marker.path), "no marker on backup failure, so the next launch retries")
    }

    /// `runIfNeeded` called twice on the SAME store instance: the marker file the first call
    /// writes must make the second call a pure no-op (returns nil, moves nothing) — the launch
    /// path's own idempotency, not just the pure migration function's (already covered by
    /// `secondRunChangesNothing` above).
    @Test func runIfNeededTwiceOnSameStoreIsANoOpTheSecondTime() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("kronos-runtwice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        setenv("KRONOS_STORE_DIR", tempRoot.path, 1)
        defer { unsetenv("KRONOS_STORE_DIR") }

        let store = try TaskStore(inMemory: true)
        store.createNoUndo(title: "Undated todo", status: .todo, dueDay: nil)

        let first = UndatedSomedayMigration.runIfNeeded(store: store)
        #expect(first?.moved == 1)

        store.createNoUndo(title: "Another undated todo added after the first run", status: .todo, dueDay: nil)
        let second = UndatedSomedayMigration.runIfNeeded(store: store)
        #expect(second == nil, "the marker already exists: the second call must not even look at candidates")
        #expect(store.allTasks().first { $0.title.hasPrefix("Another undated") }?.status == .todo,
                "a task created after the marker was written is untouched by the second call")
    }
}
