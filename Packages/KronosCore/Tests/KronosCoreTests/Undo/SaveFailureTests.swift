// A failing save must be visible: `lastSaveError`, one notification per burst of failures, an
// emergency JSON export, and a context that stays dirty. The failure is injected through the
// store's save seam; nothing here touches the person's folders (the emergency folder is a
// scratch directory named by the test).

import Testing
import Foundation
@testable import KronosCore

private struct DiskFull: Error {}

@MainActor
@Suite(.serialized) struct SaveFailureTests {

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kronos-savefail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func emergencyFiles(in dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("emergency-") && $0.pathExtension == "json" }
    }

    private func count(_ body: () -> Void) -> [[AnyHashable: Any]] {
        var infos: [[AnyHashable: Any]] = []
        let token = NotificationCenter.default.addObserver(forName: .kronosSaveFailed, object: nil, queue: nil) {
            infos.append($0.userInfo ?? [:])
        }
        body()
        NotificationCenter.default.removeObserver(token)
        return infos
    }

    @Test func failingSaveSetsTheErrorPostsOncePerBurstAndWritesTheEmergencyFile() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TaskStore(inMemory: true)
        store.backupsDirectoryOverride = dir
        let t = store.create(title: "Typed before the disk filled up")
        #expect(store.lastSaveError == nil)

        store.saveOverride = { throw DiskFull() }
        let infos = count {
            store.setPriority(t.id, .high)
            store.update(t.id) { $0.notes = "second failing save" }
            store.update(t.id) { $0.notes = "third failing save" }
        }

        #expect(store.lastSaveError is DiskFull)
        #expect(infos.count == 1, "three failures in a row are one burst: one notification")
        #expect(store.context.hasChanges, "the context stays dirty so the next save retries everything")
        let files = emergencyFiles(in: dir)
        #expect(files.count == 1, "one emergency file for the burst")
        let path = infos.first?["emergencyBackup"] as? String
        #expect(path.map { URL(fileURLWithPath: $0).lastPathComponent } == files.first?.lastPathComponent)
        let envelope = try BackupFile.read(from: files[0])
        #expect(envelope.tasks.map(\.title) == ["Typed before the disk filled up"])
        #expect(envelope.tasks.first?.priority == KPriority.high.rawValue, "the unsaved change is in the file")
    }

    @Test func aSuccessfulSaveClearsTheErrorAndTheNextFailureNotifiesAgain() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TaskStore(inMemory: true)
        store.backupsDirectoryOverride = dir
        let t = store.create(title: "A")

        store.saveOverride = { throw DiskFull() }
        let first = count { store.setPriority(t.id, .high) }
        #expect(first.count == 1)

        store.saveOverride = nil                      // the disk has room again
        store.setPriority(t.id, .urgent)
        #expect(store.lastSaveError == nil)
        #expect(!store.context.hasChanges)

        store.saveOverride = { throw DiskFull() }
        let second = count { store.setPriority(t.id, .low) }
        #expect(second.count == 1, "a new burst notifies again")
    }

    /// Positive control: with a working save nothing is posted and nothing is written.
    @Test func healthySaveIsSilent() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TaskStore(inMemory: true)
        store.backupsDirectoryOverride = dir
        let infos = count {
            let t = store.create(title: "A")
            store.setPriority(t.id, .high)
        }
        #expect(infos.isEmpty)
        #expect(store.lastSaveError == nil)
        #expect(emergencyFiles(in: dir).isEmpty)
    }

    /// An in-memory store has no backups folder: a failure still notifies but writes no file
    /// (so a test can never write into the person's real Backups folder).
    @Test func inMemoryStoreWithoutAnOverrideWritesNoFile() throws {
        let store = try TaskStore(inMemory: true)
        #expect(store.backupsDirectory == nil)
        let t = store.create(title: "A")
        store.saveOverride = { throw DiskFull() }
        let infos = count { store.setPriority(t.id, .high) }
        #expect(infos.count == 1)
        #expect(infos.first?["emergencyBackup"] == nil)
    }
}
