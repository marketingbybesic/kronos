// Kronos/Settings/BackupScheduler.swift
// Automatic backups. Pure and injectable (clock, directory, defaults) so it is testable without
// touching the real filesystem or a wall clock.
//
//  - Daily: one JSON envelope (`kronos-<day>.json`) and one store copy (`kronos-<day>.store`),
//    written once per day, at launch and on `.kronosDayDidChange`.
//  - Rolling: `kronos-today.store`, retaken when the app resigns active and when it quits (at most
//    every five minutes, quit always). This is the copy that is never more than minutes old.
//  - Second folder (optional): the same files are copied there after every backup.
//  - Pruning follows `BackupPolicy` (KronosCore): daily count, safety files by age, interrupted
//    snapshots; the rolling copy and pre-migration folders are never touched.
//  - Hermetic runs (live test, hand test with KRONOS_STORE_DIR): the folder is under the scratch
//    store directory and the flags live in `KronosEnv.defaults`, so the person's data is never read.

import Foundation
import KronosCore

@MainActor
struct BackupScheduler {
    let store: TaskStore
    var clock: () -> Date = Date.init
    var directory: URL = BackupScheduler.defaultDirectory
    var defaults: UserDefaults = KronosEnv.defaults
    var liveStore: URL = KronosStore.storeURL()

    nonisolated static var defaultDirectory: URL {
        KronosEnv.storeDirectory.appendingPathComponent("Backups", isDirectory: true)
    }

    // MARK: Settings (all through the defaults suite)

    nonisolated static let lastBackupKey = "kronos.backup.lastBackupAt"
    nonisolated static let lastRollingKey = "kronos.backup.lastRollingAt"
    nonisolated static let secondFolderKey = "kronos.backup.secondFolder"
    nonisolated static let secondFolderFailedKey = "kronos.backup.secondFolderFailed"

    nonisolated static func lastBackupDate(_ defaults: UserDefaults = KronosEnv.defaults) -> Date? {
        guard let t = defaults.object(forKey: lastBackupKey) as? Double else { return nil }
        return Date(timeIntervalSince1970: t)
    }

    nonisolated static func secondFolder(_ defaults: UserDefaults = KronosEnv.defaults) -> URL? {
        guard let path = defaults.string(forKey: secondFolderKey), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    nonisolated static func setSecondFolder(_ url: URL?, _ defaults: UserDefaults = KronosEnv.defaults) {
        if let url { defaults.set(url.path, forKey: secondFolderKey) } else { defaults.removeObject(forKey: secondFolderKey) }
        defaults.set(false, forKey: secondFolderFailedKey)
    }

    nonisolated static func secondFolderFailed(_ defaults: UserDefaults = KronosEnv.defaults) -> Bool {
        defaults.bool(forKey: secondFolderFailedKey)
    }

    private var dayFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }

    // MARK: Daily

    /// Writes today's backup if one does not already exist, then prunes.
    /// Returns the file written, or nil if today's backup already existed (or backups are off).
    @discardableResult
    func runIfNeeded() -> URL? {
        guard AppSettingsStore2.dailyBackupEnabled else { return nil }
        let now = clock()
        let day = dayFormatter.string(from: now)
        let url = directory.appendingPathComponent("kronos-\(day).json")
        snapshotStoreIfNeeded(day: day, now: now)
        guard !FileManager.default.fileExists(atPath: url.path) else { prune(now: now); return nil }
        var envelope = JSONExporter(store: store).makeEnvelope(now: now)
        let templates = TemplateStore.shared.templates
        if !templates.isEmpty { envelope.templates = templates }
        do {
            try BackupFile.write(envelope, to: url)
            recordSuccess(now: now)
            copyToSecondFolder(url, now: now)
        } catch {
            // The store copy above (and the next launch) still protect the data.
        }
        prune(now: now)
        return url
    }

    /// Today's copy of the live SQLite store (`kronos-<day>.store`), the thing Settings > Data >
    /// "Restore from backup" lists. Taken with SQLite's online-backup API, so it is consistent
    /// while the app has the store open.
    private func snapshotStoreIfNeeded(day: String, now: Date) {
        let dest = directory.appendingPathComponent("kronos-\(day).store")
        guard !FileManager.default.fileExists(atPath: dest.path) else { return }
        if (try? BackupRestore.snapshot(from: liveStore, to: dest)) != nil {
            recordSuccess(now: now)
            copyToSecondFolder(dest, now: now)
        }
    }

    // MARK: Rolling

    /// Retakes `kronos-today.store`. `force` (quit) ignores the five-minute spacing. Returns true
    /// when a new copy was written. Call after the context has been saved.
    @discardableResult
    func runRolling(force: Bool) -> Bool {
        guard AppSettingsStore2.dailyBackupEnabled else { return false }
        let now = clock()
        let last = (defaults.object(forKey: Self.lastRollingKey) as? Double).map { Date(timeIntervalSince1970: $0) }
        guard BackupPolicy.rollingDue(last: last, now: now, force: force) else { return false }
        let dest = directory.appendingPathComponent(BackupPolicy.rollingStoreName)
        // A store with no tasks at all must not replace a copy that may still hold them: whatever
        // emptied it (a bad import, a damaged file) is exactly when the old copy is needed.
        if FileManager.default.fileExists(atPath: dest.path), store.allTasksIncludingDeleted().isEmpty { return false }
        do { try BackupRestore.snapshot(from: liveStore, to: dest) } catch { return false }
        defaults.set(now.timeIntervalSince1970, forKey: Self.lastRollingKey)
        recordSuccess(now: now)
        copyToSecondFolder(dest, now: now)
        prune(now: now)
        return true
    }

    // MARK: Second folder

    private func recordSuccess(now: Date) {
        defaults.set(now.timeIntervalSince1970, forKey: Self.lastBackupKey)
    }

    /// Copies one finished backup file into the second folder (replacing a same-named file) and
    /// prunes it by the same rules. A folder that cannot be written sets a flag Settings shows.
    private func copyToSecondFolder(_ file: URL, now: Date) {
        guard let second = Self.secondFolder(defaults) else { return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: second, withIntermediateDirectories: true)
            let dest = second.appendingPathComponent(file.lastPathComponent)
            let partial = dest.appendingPathExtension("partial")
            try? fm.removeItem(at: partial)
            try fm.copyItem(at: file, to: partial)
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: partial, to: dest)
            defaults.set(false, forKey: Self.secondFolderFailedKey)
            Self.prune(in: second, now: now)
        } catch {
            defaults.set(true, forKey: Self.secondFolderFailedKey)
        }
    }

    // MARK: Pruning

    func prune(now: Date? = nil) {
        Self.prune(in: directory, now: now ?? clock())
    }

    /// Applies `BackupPolicy.pruneVictims` to the regular files directly inside `directory`
    /// (folders such as a pre-migration copy are skipped) and removes each victim's -wal/-shm.
    nonisolated static func prune(in directory: URL, now: Date) {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]) else { return }
        let entries = urls.compactMap { url -> BackupPolicy.Entry? in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
            guard values?.isDirectory != true, let date = values?.contentModificationDate else { return nil }
            return BackupPolicy.Entry(name: url.lastPathComponent, date: date)
        }
        for name in BackupPolicy.pruneVictims(entries, now: now) {
            let url = directory.appendingPathComponent(name)
            try? fm.removeItem(at: url)
            for suffix in ["-wal", "-shm"] { try? fm.removeItem(atPath: url.path + suffix) }
        }
    }
}

/// Separate from `AppSettingsStore` (AISettingsController.swift) only to keep each file
/// under the owning feature's name; both are the same kind of small UserDefaults wrapper.
enum AppSettingsStore2 {
    private static let key = "kronos.data.dailyBackupEnabled"
    static var dailyBackupEnabled: Bool {
        get { KronosEnv.defaults.object(forKey: key) == nil ? true : KronosEnv.defaults.bool(forKey: key) }
        set { KronosEnv.defaults.set(newValue, forKey: key) }
    }
}
