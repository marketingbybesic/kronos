// The 30-day purge: a pre-purge export first, nothing when the clock is behind the latest clock
// seen, nothing when the export cannot be written. The clock mark lives in an in-memory fixture.

import Testing
import Foundation
@testable import KronosCore

@MainActor
@Suite(.serialized) struct PurgeGuardTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)   // a fixed instant
    private let day: TimeInterval = 86_400

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kronos-purge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func prePurgeFiles(in dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("pre-purge-") && $0.pathExtension == "json" }
    }

    /// A store with one task deleted 40 days before `now` and one deleted 2 days before.
    private func makeStore(backups: URL) throws -> (TaskStore, old: UUID, recent: UUID) {
        let store = try TaskStore(inMemory: true)
        store.backupsDirectoryOverride = backups
        let old = store.createNoUndo(title: "Deleted long ago")
        let recent = store.createNoUndo(title: "Deleted lately")
        store.updateIncludingDeleted(old.id) { $0.deletedAt = self.now.addingTimeInterval(-40 * self.day) }
        store.updateIncludingDeleted(recent.id) { $0.deletedAt = self.now.addingTimeInterval(-2 * self.day) }
        return (store, old.id, recent.id)
    }

    @Test func writesAPrePurgeExportBeforeDeletingAndKeepsRecentRows() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, old, recent) = try makeStore(backups: dir)

        store.purgeDeletedOlderThan(days: 30, now: now)

        let files = prePurgeFiles(in: dir)
        #expect(files.count == 1)
        let envelope = try BackupFile.read(from: files[0])
        #expect(envelope.tasks.map(\.title).sorted() == ["Deleted lately", "Deleted long ago"],
                "the export holds the rows the purge is about to delete")
        #expect(store.taskIncludingDeleted(old) == nil, "the old row is gone")
        #expect(store.taskIncludingDeleted(recent) != nil, "the recent row stays")
    }

    @Test func nothingToPurgeWritesNoFile() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TaskStore(inMemory: true)
        store.backupsDirectoryOverride = dir
        store.createNoUndo(title: "Alive")
        store.purgeDeletedOlderThan(days: 30, now: now)
        #expect(prePurgeFiles(in: dir).isEmpty)
    }

    @Test func aClockBehindTheLatestSeenNowSkipsThePurge() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, old, _) = try makeStore(backups: dir)

        // The latest clock this store has seen is `now`; the clock then jumps back an hour.
        store.purgeClockMarkOverride = FixtureKeyValueStore()
        store.purgeClockMarkOverride?.setInteger(Int(now.timeIntervalSince1970), forKey: TaskStore.purgeClockMarkKey)
        store.purgeDeletedOlderThan(days: 30, now: now.addingTimeInterval(-3600))
        #expect(store.taskIncludingDeleted(old) != nil, "a clock set back purges nothing")
        #expect(prePurgeFiles(in: dir).isEmpty, "and writes no export")

        // Back at (or past) the mark it runs.
        store.purgeDeletedOlderThan(days: 30, now: now)
        #expect(store.taskIncludingDeleted(old) == nil)
    }

    @Test func aFreshStoreWithNoMarkPurgesAndRecordsTheClock() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, old, _) = try makeStore(backups: dir)
        store.purgeDeletedOlderThan(days: 30, now: now)
        #expect(store.taskIncludingDeleted(old) == nil)
        #expect(store.purgeClockMark.integer(forKey: TaskStore.purgeClockMarkKey) == Int(now.timeIntervalSince1970))
    }

    @Test func aFailedExportPurgesNothing() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A plain FILE where the backups folder must go: the export cannot be written.
        let blocked = dir.appendingPathComponent("Backups")
        FileManager.default.createFile(atPath: blocked.path, contents: Data())
        let (store, old, _) = try makeStore(backups: blocked)

        store.purgeDeletedOlderThan(days: 30, now: now)
        #expect(store.taskIncludingDeleted(old) != nil, "no safety copy, no delete")
    }

    /// The day-change coordinator advances the same mark on every trigger and never lowers it, so
    /// a purge after the clock went back is skipped even when no purge ran in between.
    @Test func theDayChangeCoordinatorAdvancesTheMarkAndNeverLowersIt() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, old, _) = try makeStore(backups: dir)
        let shared = FixtureKeyValueStore()
        store.purgeClockMarkOverride = shared

        let clock = FixtureClock(now: now)
        let coordinator = DayChangeCoordinator(clock: clock, scheduler: NoScheduler(), defaults: shared)
        coordinator.start()
        #expect(shared.integer(forKey: TaskStore.purgeClockMarkKey) == Int(now.timeIntervalSince1970))

        clock.now = now.addingTimeInterval(-5 * day)       // the clock is set back five days
        coordinator.checkForDayChange()
        #expect(shared.integer(forKey: TaskStore.purgeClockMarkKey) == Int(now.timeIntervalSince1970), "never lowered")

        store.purgeDeletedOlderThan(days: 30, now: clock.now)
        #expect(store.taskIncludingDeleted(old) != nil, "skipped while the clock is behind")
    }
}

@MainActor
private final class NoScheduler: DayChangeScheduling {
    func schedule(at date: Date, _ fire: @escaping () -> Void) {}
    func cancel() {}
}
