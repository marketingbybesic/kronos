import Testing
import Foundation
@testable import KronosCore

/// The pre-upgrade copy of the store files (Kronos.store, -wal, -shm) with injected file
/// operations. The step conversion itself is covered by `LegacyStepConversionTests`, the
/// on-disk open through the real migration plan by `SchemaV2MigrationTests`.
@Suite("SubtaskMigrationTests")
struct SubtaskMigrationTests {
    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: backup files, injected file operations (a temp dir, never the real Application Support)

    /// A temp container holding Kronos.store, -wal and -shm with known bytes.
    private func container() throws -> (dir: URL, store: URL) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("subtask-backup-\(UUID())")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = dir.appendingPathComponent("Kronos.store")
        for (suffix, body) in [("", "main-bytes"), ("-wal", "wal-bytes"), ("-shm", "shm")] {
            try Data(body.utf8).write(to: URL(fileURLWithPath: store.path + suffix))
        }
        return (dir, store)
    }

    /// File operations that break one named file the way a full disk or a bad copy would.
    private struct FaultOps: MigrationFileOps {
        var failCopyOf: String?       // copy throws (disk full)
        var skipCopyOf: String?       // copy "succeeds" but writes nothing
        var truncateCopyOf: String?   // copy succeeds, destination is cut short
        private let real = DefaultMigrationFileOps()
        func exists(_ url: URL) -> Bool { real.exists(url) }
        func createDirectory(_ url: URL) throws { try real.createDirectory(url) }
        func size(_ url: URL) throws -> Int { try real.size(url) }
        func remove(_ url: URL) throws { try real.remove(url) }
        func write(_ url: URL, _ data: Data) { real.write(url, data) }
        func copy(_ from: URL, _ to: URL) throws {
            let name = from.lastPathComponent
            if name == failCopyOf { throw CocoaError(.fileWriteOutOfSpace) }
            if name == skipCopyOf { return }
            try real.copy(from, to)
            if name == truncateCopyOf { try Data("x".utf8).write(to: to) }
        }
    }

    private func backupsFolder(_ dir: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("Backups").path)) ?? []
    }

    @Test func backupCopiesTheStoreAndItsWalAndShm() throws {
        let fm = FileManager.default
        let (dir, store) = try container()
        defer { try? fm.removeItem(at: dir) }
        let empty = fm.temporaryDirectory.appendingPathComponent("subtask-none-\(UUID())")
        #expect(SubtaskToTaskMigration.backupStoreFiles(store: empty.appendingPathComponent("Kronos.store"),
                                                       container: empty, now: Self.t0) == .notNeeded,
                "no store file, nothing to back up")
        guard case .made(let out) = SubtaskToTaskMigration.backupStoreFiles(store: store, container: dir, now: Self.t0) else {
            Issue.record("backup should succeed"); return
        }
        #expect(out.deletingLastPathComponent().lastPathComponent == "Backups")
        #expect(out.lastPathComponent == "pre-v2-2026-09-21T141320Z")
        let copied = try fm.contentsOfDirectory(atPath: out.path).sorted()
        #expect(copied == ["Kronos.store", "Kronos.store-shm", "Kronos.store-wal"])
        #expect(try String(contentsOf: out.appendingPathComponent("Kronos.store-wal"), encoding: .utf8) == "wal-bytes")
        #expect(SubtaskToTaskMigration.takePendingNotice(container: dir) == nil, "success queues no notice")
    }

    @Test func failedCopyRemovesThePartialFolderAndQueuesTheNotice() throws {
        let fm = FileManager.default
        let (dir, store) = try container()
        defer { try? fm.removeItem(at: dir) }
        let result = SubtaskToTaskMigration.backupStoreFiles(
            store: store, container: dir, now: Self.t0, ops: FaultOps(failCopyOf: "Kronos.store-wal"))
        let reason = CocoaError(.fileWriteOutOfSpace).localizedDescription
        #expect(result == .failed(reason: reason))
        #expect(!reason.isEmpty)
        #expect(backupsFolder(dir).isEmpty, "the half-written folder (Kronos.store copied, -wal not) is gone")

        // The notice is queued once, with the reason and the Backups folder path.
        let notice = try #require(SubtaskToTaskMigration.takePendingNotice(container: dir))
        #expect(notice.reason == reason)
        #expect(notice.folder == dir.appendingPathComponent("Backups").path)
        #expect(SubtaskToTaskMigration.takePendingNotice(container: dir) == nil, "shown once")
    }

    @Test func aShortOrMissingCopyCountsAsIncomplete() throws {
        let fm = FileManager.default
        for ops in [FaultOps(truncateCopyOf: "Kronos.store-shm"), FaultOps(skipCopyOf: "Kronos.store")] {
            let (dir, store) = try container()
            defer { try? fm.removeItem(at: dir) }
            let result = SubtaskToTaskMigration.backupStoreFiles(store: store, container: dir, now: Self.t0, ops: ops)
            guard case .failed(let reason) = result else { Issue.record("expected failure, got \(result)"); continue }
            #expect(reason.hasPrefix("incomplete copy of Kronos.store"))
            #expect(backupsFolder(dir).isEmpty)
            #expect(SubtaskToTaskMigration.takePendingNotice(container: dir) != nil)
        }
    }
}
