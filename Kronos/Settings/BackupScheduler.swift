// Kronos/Settings/BackupScheduler.swift
// Daily automatic backup: writes one JSON envelope into the backups folder and prunes to
// the newest 14. Pure and injectable (clock, directory) so it is testable without touching
// the real filesystem or a wall clock, and so the caller can wire it to
// `.kronosDayDidChange` without owning any of its logic.
//
// Wiring: on `.kronosDayDidChange` (Runtime.swift, already posted by the day-change
// coordinator), call `BackupScheduler(store: appModel.store).runIfNeeded()` once. The
// scheduler itself decides whether a backup already exists for today.

import Foundation
import KronosCore

@MainActor
struct BackupScheduler {
    let store: TaskStore
    var clock: () -> Date = Date.init
    var directory: URL = BackupScheduler.defaultDirectory
    var keep: Int = 14

    static var defaultDirectory: URL {
        KronosStore.containerDirectory().appendingPathComponent("Backups", isDirectory: true)
    }

    private var dayFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }

    /// Writes today's backup if one does not already exist, then prunes to `keep`.
    /// Returns the file written, or nil if today's backup already existed.
    @discardableResult
    func runIfNeeded() -> URL? {
        guard AppSettingsStore2.dailyBackupEnabled else { return nil }
        let now = clock()
        let name = "kronos-\(dayFormatter.string(from: now)).json"
        let url = directory.appendingPathComponent(name)
        snapshotStoreIfNeeded(day: dayFormatter.string(from: now))
        guard !FileManager.default.fileExists(atPath: url.path) else { prune(); return nil }
        var envelope = JSONExporter(store: store).makeEnvelope(now: now)
        let templates = TemplateStore.shared.templates
        if !templates.isEmpty { envelope.templates = templates }
        try? BackupFile.write(envelope, to: url)
        prune()
        return url
    }

    /// Also keeps today's copy of the live SQLite store (`kronos-<day>.store`), the thing
    /// Settings > Data > "Restore from backup" lists. Taken with SQLite's online-backup API, so
    /// it is consistent while the app has the store open. A failure is silent: the JSON backup
    /// above is still written, and the next launch tries again.
    private func snapshotStoreIfNeeded(day: String, live: URL = KronosStore.storeURL()) {
        let dest = directory.appendingPathComponent("kronos-\(day).store")
        guard !FileManager.default.fileExists(atPath: dest.path) else { return }
        try? BackupRestore.snapshot(from: live, to: dest)
    }

    /// Deletes the oldest files beyond `keep`, sorted by filename (which is the date). JSON and
    /// store copies are counted separately, so each keeps its own 14.
    func prune() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return }
        for ext in ["json", "store"] {
            let backups = files.filter { $0.lastPathComponent.hasPrefix("kronos-") && $0.pathExtension == ext }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard backups.count > keep else { continue }
            for url in backups.prefix(backups.count - keep) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

/// Separate from `AppSettingsStore` (AISettingsController.swift) only to keep each file
/// under the owning feature's name; both are the same kind of small UserDefaults wrapper.
enum AppSettingsStore2 {
    private static let key = "kronos.data.dailyBackupEnabled"
    static var dailyBackupEnabled: Bool {
        get { UserDefaults.standard.object(forKey: key) == nil ? true : UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
