// One-time catch-up for tasks created before the automatic status rule
// (TaskStore.swift:367-388) existed. That rule only fires on a due-day EDIT, so it never
// touched a task at rest with `dueDay == nil` created earlier — a real store was found with 35
// such `.todo` tasks invisible to Someday. This is the migration that closes that gap, once.
//
// Extensions in a separate file cannot see `private` members, so this relies on the same
// internal (not private) undo plumbing TaskStore+NoUndo.swift already uses: `isMachineWrite`,
// `saveContext`. It writes statusRaw directly (not through `update`/`updateNoUndo`) because a
// 35-row batch through the undoable path would still be undo-free via `withoutUndo`, but that
// helper is `private` to TaskStore.swift and unreachable from here — going around it the same
// way `withoutUndo` itself does (flip `isMachineWrite`, mutate, save once) keeps this a single
// save instead of 35, and confirms no undo step is pushed without depending on a method this
// file cannot call.

import Foundation

@MainActor
extension TaskStore {

    /// The result of one migration run.
    public struct UndatedSomedayMigrationResult: Equatable, Sendable {
        public let moved: Int
    }

    /// Every task with status `.todo`, `dueDay == nil`, not soft-deleted -> `.someday`.
    /// NOT `.inProgress`, NOT `.waiting`, not `.done`/`.canceled` (closed statuses are left
    /// alone; `.someday` already-undated tasks are a no-op since they already match).
    ///
    /// Subtasks (`KSubtask`) carry no `status` and no `dueDay` of their own (Contracts.swift) —
    /// there is nothing to migrate there; they simply move with whatever happens to their
    /// parent task automatically (they have no independent list membership).
    ///
    /// `updatedAt` is left UNTOUCHED: this is a data-shape correction, not a user edit —
    /// bumping `updatedAt` would make 35 tasks jump to the top of any "recently changed"
    /// sort/view for a change the user never made, which is a worse surprise than the bug this
    /// migration fixes. Every other Core writer (`mutateUndoable`, importers) always stamps
    /// `updatedAt` for a real edit; a silent background reclassification is deliberately not one.
    ///
    /// NO UNDO — this fires once at launch, before any window is visible, long before the user
    /// could press Cmd-Z for it; registering 35 undo steps (or one grouped step) at startup
    /// would also let an early Cmd-Z reopen exactly the bug this migration fixes.
    ///
    /// ONE save for the whole batch, not one per row.
    @discardableResult
    public static func migrateUndatedTodoToSomeday(store: TaskStore) -> UndatedSomedayMigrationResult {
        let candidates = store.allTasks().filter {
            $0.status == .todo && $0.dueDay == nil
        }
        guard !candidates.isEmpty else { return UndatedSomedayMigrationResult(moved: 0) }

        let wasMachine = store.isMachineWrite
        store.isMachineWrite = true
        for t in candidates {
            t.status = .someday
            t.ordoIndex = nil
        }
        store.isMachineWrite = wasMachine
        store.saveContext()
        return UndatedSomedayMigrationResult(moved: candidates.count)
    }
}

// MARK: - Launch-time entry point (marker file + backup, called once from AppDelegate)

@MainActor
public enum UndatedSomedayMigration {
    /// Relative to `KronosStore.containerDirectory()` (Runtime.swift:72) — the same
    /// KRONOS_STORE_DIR-hermetic root every store/backup path already uses, so this is
    /// hermetic under tests and under the migration copy-check script's copy too.
    static let markerRelativePath = "migrations/undatedSomeday.v1"

    /// Same folder name `BackupScheduler.defaultDirectory` writes to
    /// (Kronos/Settings/BackupScheduler.swift:20-22: `containerDirectory() + "Backups"`) — one
    /// backups folder, not a second one this migration invents.
    private static let backupsDirectoryName = "Backups"

    /// Call once, right after the store opens (and, on first launch, after `seedIfEmpty()` has
    /// had a chance to populate it) and before the first window renders. Idempotent: a marker
    /// file at `markerRelativePath` guards every run after the first.
    ///
    /// Backs up first via the SAME `BackupFile.write` + envelope machinery the daily scheduler
    /// uses (`Export/BackupFile.swift:30`, `JSONExporter.makeEnvelope`) — never a hand-rolled
    /// copy. If the backup write throws, the migration is skipped entirely (no marker written
    /// either, so the next launch retries) rather than mutating data with no safety copy.
    @discardableResult
    public static func runIfNeeded(store: TaskStore, now: Date = Date()) -> TaskStore.UndatedSomedayMigrationResult? {
        let root = KronosStore.containerDirectory()
        let marker = root.appendingPathComponent(markerRelativePath)
        guard !FileManager.default.fileExists(atPath: marker.path) else { return nil }

        let backupsDir = root.appendingPathComponent(backupsDirectoryName, isDirectory: true)
        // Deliberately NOT prefixed "kronos-": BackupScheduler.prune() (Settings/BackupScheduler
        // .swift:49-56) sweeps every "kronos-*.json" file in this folder, sorted by filename, and
        // keeps only the newest 14 — a "kronos-"-prefixed name here would occupy one of the
        // 14 daily-backup slots forever (it never sorts old enough to be pruned) and
        // silently push a real daily backup out. This name is invisible to that filter.
        let backupName = "pre-migration-undatedSomeday-v1-\(ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "")).json"
        let backupURL = backupsDir.appendingPathComponent(backupName)
        let envelope = JSONExporter(store: store).makeEnvelope(now: now)
        do {
            try BackupFile.write(envelope, to: backupURL)
        } catch {
            // Backup failed: skip the migration, write no marker, so the next launch retries.
            return nil
        }

        let result = TaskStore.migrateUndatedTodoToSomeday(store: store)
        try? FileManager.default.createDirectory(at: marker.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: marker.path, contents: Data("1".utf8))
        return result
    }
}
