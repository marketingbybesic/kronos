import Foundation
import SwiftData
import Testing
@testable import KronosCore

/// Launch migrations are marked inside the store, honour the marker files earlier builds wrote,
/// and never run on a synced store. Seeding waits for the first import when sync is on.
/// Marker files live in a scratch folder passed explicitly (no environment variable).
@MainActor
@Suite("StoreMarkerTests")
struct StoreMarkerTests {

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kronos-markers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func files(_ dir: URL) -> (subtasks: URL, undated: URL) {
        (dir.appendingPathComponent(SubtaskToTaskMigration.markerRelativePath),
         dir.appendingPathComponent(UndatedSomedayMigration.markerRelativePath))
    }

    /// The decision table, by hand: (storeMarked, fileMarked, syncEnabled) -> decision.
    static let gate: [(Bool, Bool, Bool, MigrationGate.Decision)] = [
        (false, false, false, .run),
        (false, true, false, .adoptFileMarker),
        (true, false, false, .alreadyDone),
        (true, true, false, .alreadyDone),
        (false, false, true, .skipSyncEnabled),
        (false, true, true, .skipSyncEnabled),
        (true, false, true, .skipSyncEnabled),
        (true, true, true, .skipSyncEnabled),
    ]

    @Test func gateFollowsTheTable() {
        for (store, file, sync, want) in Self.gate {
            #expect(MigrationGate.decide(storeMarked: store, fileMarked: file, syncEnabled: sync) == want,
                    "store=\(store) file=\(file) sync=\(sync)")
        }
    }

    /// (syncEnabled, importDone) -> seed?
    static let seed: [(Bool, Bool, Bool)] = [(false, false, true), (false, true, true), (true, false, false), (true, true, true)]

    @Test func seedPolicyFollowsTheTable() {
        for (sync, done, want) in Self.seed {
            #expect(SeedPolicy.shouldSeed(syncEnabled: sync, importDone: done) == want, "sync=\(sync) done=\(done)")
        }
    }

    /// The acceptance case: a fresh store with sync on runs neither migration and writes no
    /// marker (no row, no file).
    @Test func freshStoreWithSyncOnRunsNeither() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TaskStore(inMemory: true)
        let f = files(dir)
        let a = SubtaskToTaskMigration.runIfNeeded(store: store, backup: .notNeeded, marker: f.subtasks, syncEnabled: true)
        let b = UndatedSomedayMigration.runIfNeeded(store: store, marker: f.undated, syncEnabled: true)
        #expect(a == nil)
        #expect(b == nil)
        #expect(store.metaValue(StoreMetaKey.subtasksToTasks) == nil)
        #expect(store.metaValue(StoreMetaKey.undatedSomeday) == nil)
        #expect(!FileManager.default.fileExists(atPath: f.subtasks.path))
        #expect(!FileManager.default.fileExists(atPath: f.undated.path))
        #expect(((try? store.context.fetch(FetchDescriptor<KStoreMeta>())) ?? []).isEmpty)
    }

    /// Sync off, nothing marked: both run once and mark the store; the second launch runs none.
    @Test func firstRunMarksTheStoreAndTheSecondDoesNothing() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TaskStore(inMemory: true)
        let f = files(dir)
        let first = SubtaskToTaskMigration.runIfNeeded(store: store, backup: .notNeeded, marker: f.subtasks, syncEnabled: false)
        #expect(first == SubtaskToTaskMigration.Result(converted: 0, orphans: 0, alreadyTasks: 0))
        #expect(UndatedSomedayMigration.runIfNeeded(store: store, marker: f.undated, syncEnabled: false)?.moved == 0)
        #expect(store.metaValue(StoreMetaKey.subtasksToTasks) == "1")
        #expect(store.metaValue(StoreMetaKey.undatedSomeday) == "1")
        // Second launch, marker files gone (another device on the same store): still nothing.
        try FileManager.default.removeItem(at: f.subtasks)
        try FileManager.default.removeItem(at: f.undated)
        #expect(SubtaskToTaskMigration.runIfNeeded(store: store, backup: .notNeeded, marker: f.subtasks, syncEnabled: false) == nil)
        #expect(UndatedSomedayMigration.runIfNeeded(store: store, marker: f.undated, syncEnabled: false) == nil)
        #expect(!FileManager.default.fileExists(atPath: f.subtasks.path))
    }

    /// A marker file from an earlier build: nothing runs, the store is marked from it.
    @Test func oldMarkerFilesAreHonouredAndCopiedIntoTheStore() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TaskStore(inMemory: true)
        let f = files(dir)
        for url in [f.subtasks, f.undated] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data("1".utf8))
        }
        #expect(SubtaskToTaskMigration.runIfNeeded(store: store, backup: .notNeeded, marker: f.subtasks, syncEnabled: false) == nil)
        #expect(UndatedSomedayMigration.runIfNeeded(store: store, marker: f.undated, syncEnabled: false) == nil)
        #expect(store.metaValue(StoreMetaKey.subtasksToTasks) == "1")
        #expect(store.metaValue(StoreMetaKey.undatedSomeday) == "1")
    }

    /// Two marker rows for one key (two devices before a sync settled): the newest wins, and a
    /// write updates that row instead of adding a third.
    @Test func newestMarkerRowWins() throws {
        let store = try TaskStore(inMemory: true)
        store.context.insert(KStoreMeta(key: "k", value: "old", updatedAt: Date(timeIntervalSince1970: 100)))
        store.context.insert(KStoreMeta(key: "k", value: "new", updatedAt: Date(timeIntervalSince1970: 200)))
        try store.context.save()
        #expect(store.metaValue("k") == "new")
        store.setMeta("k", "newer", now: Date(timeIntervalSince1970: 300))
        #expect(store.metaValue("k") == "newer")
        #expect(store.metaRows("k").count == 2)
        #expect(store.metaValue("missing") == nil)
    }

    /// The schema minimum only rises, and with rows from two devices the highest counts.
    @Test func schemaMinimumOnlyRises() throws {
        let store = try TaskStore(inMemory: true)
        #expect(store.storeMinimumSchemaVersion == nil)
        #expect(store.raiseStoreMinimumSchemaVersion(to: 2))
        #expect(store.storeMinimumSchemaVersion == 2)
        #expect(!store.raiseStoreMinimumSchemaVersion(to: 1))
        #expect(store.storeMinimumSchemaVersion == 2)
        // An older device wrote 2 AFTER a newer one wrote 3.
        store.context.insert(KStoreMeta(key: StoreMetaKey.minSchemaVersion, value: "3", updatedAt: Date(timeIntervalSince1970: 10)))
        try store.context.save()
        #expect(store.storeMinimumSchemaVersion == 3)
        DedupeSweep.run(in: store)
        #expect(store.metaRows(StoreMetaKey.minSchemaVersion).map(\.value) == ["3"])
    }
}
