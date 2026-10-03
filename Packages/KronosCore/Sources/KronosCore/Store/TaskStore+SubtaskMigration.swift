// Launch-time safety copy and marker around the schema V2 upgrade.
//
// Steps used to be separate rows; they became child tasks, first through a one-time launch
// conversion and now inside the V1 -> V2 migration stage (Store/SchemaV2Stage.swift), which turns
// any step row left in an older store or a restored backup into a child task before the step
// table is dropped. What remains here runs around that open:
//   - `backupStoreFilesIfNeeded` copies the store files (Kronos.store + -wal + -shm) into
//     `Backups/pre-v2-<UTC>/` BEFORE the store is opened, whenever the file on disk is not yet V2
//     (read from the store's own metadata, not from a marker). The copy is the rollback point:
//     an older build cannot open a V2 store. A failed or incomplete copy removes the partial
//     folder, queues a notice and blocks the stage, so the store is never upgraded without one.
//     After a good copy, a store written before child tasks existed (older than V1, which the
//     staged plan refuses as an unknown version) is brought to V1 first;
//   - `runIfNeeded` writes the marker once and reports what the stage converted.

import CoreData
import Foundation
import SwiftData

public enum SubtaskToTaskMigration {

    /// Relative to `KronosStore.containerDirectory()`.
    static let markerRelativePath = "migrations/subtasksToTasks.v1"
    static let storeFileSuffixes = ["", "-wal", "-shm"]
    /// Folder prefix of the pre-upgrade copy inside `Backups/`. Not prefixed "kronos-": backup
    /// pruning matches "kronos-*" files in that folder, and this copy must stay.
    static let backupFolderPrefix = "pre-v2-"

    public struct Result: Equatable, Sendable {
        /// Steps that became child tasks.
        public let converted: Int
        /// Steps with no owning task (rows an older build detached on delete). They become
        /// soft-deleted top-level tasks, so nothing is lost and the 30-day purge sweeps them.
        public let orphans: Int
        /// Steps whose id already existed as a task (a re-run): only the legacy row is removed.
        public let alreadyTasks: Int
    }

    public static func markerURL() -> URL {
        KronosStore.containerDirectory().appendingPathComponent(markerRelativePath)
    }

    public static var isDone: Bool { FileManager.default.fileExists(atPath: markerURL().path) }

    /// How the pre-upgrade copy went.
    public enum BackupResult: Equatable, Sendable {
        /// Nothing to back up (the store is already V2, or no store file exists yet).
        case notNeeded
        /// Every file copied and verified by size; the folder holds the copy.
        case made(URL)
        /// A copy failed or came out incomplete. The partial folder is already removed, a notice
        /// is queued for the next UI launch, and the V1 -> V2 stage refuses to run this launch.
        case failed(reason: String)
    }

    /// What the user is told once when the safety copy failed (file under `migrations/`).
    public struct BackupNotice: Codable, Equatable, Sendable {
        public let reason: String
        /// The Backups folder the copy was meant for (the partial copy inside it is removed).
        public let folder: String
    }

    static let noticeRelativePath = "migrations/subtasksToTasks.v1.backup-failed"

    /// Returns the queued notice and clears it, so it is shown once. Nil when none.
    public static func takePendingNotice(container: URL = KronosStore.containerDirectory()) -> BackupNotice? {
        let url = container.appendingPathComponent(noticeRelativePath)
        guard let data = try? Data(contentsOf: url),
              let notice = try? JSONDecoder().decode(BackupNotice.self, from: data) else { return nil }
        try? FileManager.default.removeItem(at: url)
        return notice
    }

    /// Call BEFORE the store is opened. When the store file exists and is not V2, copy it into
    /// `Backups/pre-v2-<UTC>/`. On failure the stage is blocked for this launch, so opening the
    /// store throws and the data stays V1, untouched.
    @discardableResult
    public static func backupStoreFilesIfNeeded(now: Date = Date()) -> BackupResult {
        backupBeforeV2(store: KronosStore.storeURL(), container: KronosStore.containerDirectory(), now: now)
    }

    /// As above with explicit paths, file operations and version probe (tests). After a good copy
    /// a store older than V1 is brought to V1 (`SchemaV2Upgrade.bringOlderStoreToV1`), so the
    /// open that follows can stage it to V2; without a copy nothing is touched.
    static func backupBeforeV2(store: URL, container: URL, now: Date,
                               ops: MigrationFileOps = DefaultMigrationFileOps(),
                               isV2: (URL) -> Bool? = SchemaV2Upgrade.storeIsV2(at:)) -> BackupResult {
        let result: BackupResult
        if !ops.exists(store) || isV2(store) == true {
            result = .notNeeded
        } else {
            result = backupStoreFiles(store: store, container: container, now: now, ops: ops)
        }
        if case .failed = result {
            SchemaV2Upgrade.setBlocked(true)
        } else {
            SchemaV2Upgrade.setBlocked(false)
            if case .made = result { SchemaV2Upgrade.bringOlderStoreToV1(at: store) }
        }
        return result
    }

    /// The copy itself, with explicit paths and injectable file operations (tests). Every copied
    /// file is checked to exist with the source's size; any failure removes the partial folder,
    /// queues the notice and returns `.failed`.
    static func backupStoreFiles(store: URL, container: URL, now: Date,
                                 ops: MigrationFileOps = DefaultMigrationFileOps()) -> BackupResult {
        guard ops.exists(store) else { return .notNeeded }
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "")
        let backups = container.appendingPathComponent("Backups", isDirectory: true)
        let dir = backups.appendingPathComponent(backupFolderPrefix + stamp, isDirectory: true)
        do {
            try ops.createDirectory(dir)
            for suffix in storeFileSuffixes {
                let src = URL(fileURLWithPath: store.path + suffix)
                guard ops.exists(src) else { continue }
                let dst = dir.appendingPathComponent(src.lastPathComponent)
                try ops.copy(src, dst)
                guard ops.exists(dst) else { throw BackupError.incomplete(src.lastPathComponent) }
                let want = try ops.size(src), got = try ops.size(dst)
                guard want == got else { throw BackupError.incomplete(src.lastPathComponent) }
            }
            return .made(dir)
        } catch {
            try? ops.remove(dir)
            let reason = (error as? BackupError)?.description ?? error.localizedDescription
            writeNotice(BackupNotice(reason: reason, folder: backups.path), container: container)
            FileHandle.standardError.write(Data("Kronos: store upgrade skipped, safety copy failed: \(reason)\n".utf8))
            return .failed(reason: reason)
        }
    }

    enum BackupError: Error, CustomStringConvertible {
        case incomplete(String)
        var description: String {
            switch self { case .incomplete(let name): return "incomplete copy of \(name)" }
        }
    }

    private static func writeNotice(_ notice: BackupNotice, container: URL) {
        let url = container.appendingPathComponent(noticeRelativePath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(notice) { try? data.write(to: url) }
    }

    /// Call right after the store opened. Marker only: the conversion itself ran inside the
    /// migration stage while the store opened. Returns what the stage converted this launch
    /// (zeros when there was nothing to convert), or nil when the marker already existed and the
    /// stage converted nothing, or when the safety copy failed (no marker then, so the next
    /// launch retries). Never removes a safety copy.
    ///
    /// The marker lives in the store (`KStoreMeta`, `StoreMetaKey.subtasksToTasks`); a marker
    /// FILE from an earlier build is honoured and copied into the store. A synced store is
    /// never marked or migrated by a device on its own (`MigrationGate`).
    @MainActor @discardableResult
    public static func runIfNeeded(store: TaskStore, backup: BackupResult = .notNeeded,
                                   syncEnabled: Bool = KronosStore.isSyncEnabled) -> Result? {
        runIfNeeded(store: store, backup: backup, marker: markerURL(), syncEnabled: syncEnabled)
    }

    /// As above with an explicit marker path and file operations (tests).
    @MainActor @discardableResult
    static func runIfNeeded(store: TaskStore, backup: BackupResult, marker: URL,
                            ops: MigrationFileOps = DefaultMigrationFileOps(),
                            syncEnabled: Bool = KronosStore.isSyncEnabled) -> Result? {
        let converted = SchemaV2Upgrade.takeConverted()
        if case .failed = backup { return nil }
        let key = StoreMetaKey.subtasksToTasks
        switch MigrationGate.decide(storeMarked: store.metaValue(key) != nil,
                                    fileMarked: ops.exists(marker), syncEnabled: syncEnabled) {
        case .skipSyncEnabled, .alreadyDone:
            return converted
        case .adoptFileMarker:
            store.setMeta(key, "1")
            return converted
        case .run:
            // The file is still written for tools that look for it; the store row is what counts.
            try? ops.createDirectory(marker.deletingLastPathComponent())
            ops.write(marker, Data("1".utf8))
            store.setMeta(key, "1")
            return converted ?? Result(converted: 0, orphans: 0, alreadyTasks: 0)
        }
    }
}

/// Before/after proof of the step conversion, used by the unit tests and by the run on a COPY of
/// a real store: `capture` reads a store still on V1, `verify` reads the same data after it
/// opened as V2 and returns every violated rule (empty = converted exactly).
public enum SubtaskMigrationAudit {

    public struct Step: Equatable, Sendable {
        public let id: UUID
        public let ownerID: UUID?
        public let title: String
    }

    public struct Snapshot: Equatable, Sendable {
        public let taskCount: Int
        public let steps: [Step]
        public var titleChecksum: String { SubtaskMigrationAudit.checksum(steps.map(\.title)) }
    }

    /// Reads a V1 context (a container opened with `KronosSchemaV1`). A step of a child counts
    /// as owned by the child's parent, the one-level rule the conversion applies.
    public static func capture(v1 context: ModelContext) throws -> Snapshot {
        let steps = try context.fetch(FetchDescriptor<KronosSchemaV1.KSubtask>())
            .map { Step(id: $0.id, ownerID: $0.task.map { ($0.parent ?? $0).id }, title: $0.title) }
        let tasks = try context.fetchCount(FetchDescriptor<KronosSchemaV1.KTask>())
        return Snapshot(taskCount: tasks, steps: steps)
    }

    @MainActor
    public static func verify(_ before: Snapshot, _ store: TaskStore) -> [String] {
        verify(before, in: store.context)
    }

    /// Reads a V2 context.
    public static func verify(_ before: Snapshot, in context: ModelContext) -> [String] {
        var problems: [String] = []
        let tasks = (try? context.fetch(FetchDescriptor<KTask>())) ?? []
        let expected = before.taskCount + before.steps.count
        if tasks.count != expected { problems.append("tasks after \(tasks.count) != \(expected)") }
        let byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var titles: [String] = []
        for s in before.steps {
            guard let t = byID[s.id] else { problems.append("missing \(s.id)"); continue }
            titles.append(t.title)
            if let owner = s.ownerID {
                if t.parentID != owner || t.parent?.id != owner { problems.append("wrong parent \(s.id)") }
                if t.projectID != t.parent?.projectID { problems.append("project not inherited \(s.id)") }
            } else if t.parentID != nil || t.deletedAt == nil {
                problems.append("orphan not a deleted top-level task \(s.id)")
            }
        }
        if checksum(titles) != before.titleChecksum { problems.append("title checksum differs") }
        return problems
    }

    /// Order-independent FNV-1a 64 over the sorted titles.
    public static func checksum(_ titles: [String]) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in titles.sorted().joined(separator: "\u{1F}").utf8 {
            h ^= UInt64(byte)
            h = h &* 0x0000_0100_0000_01B3
        }
        return String(h, radix: 16)
    }
}

/// The file operations the pre-upgrade copy uses, injectable so tests never touch the real
/// Application Support folder or need a real disk failure.
protocol MigrationFileOps {
    func exists(_ url: URL) -> Bool
    func createDirectory(_ url: URL) throws
    func copy(_ from: URL, _ to: URL) throws
    func size(_ url: URL) throws -> Int
    func remove(_ url: URL) throws
    func write(_ url: URL, _ data: Data)
}

struct DefaultMigrationFileOps: MigrationFileOps {
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func copy(_ from: URL, _ to: URL) throws { try FileManager.default.copyItem(at: from, to: to) }
    func size(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? -1
    }
    func remove(_ url: URL) throws { try FileManager.default.removeItem(at: url) }
    func write(_ url: URL, _ data: Data) { FileManager.default.createFile(atPath: url.path, contents: data) }
}
