import Testing
import Foundation
@testable import KronosCore

/// Replace is the one import that deletes everything first. These cases pin the three guards in
/// front of it (a file with no tasks, the caller's safety copy, a save that fails).
@MainActor
struct ImportReplaceSafetyTests {

    private func storeWithTasks(_ titles: [String]) throws -> TaskStore {
        let store = try TaskStore(inMemory: true)
        for t in titles { _ = store.create(title: t, project: nil) }
        store.saveContext()
        return store
    }

    private func fileData(titles: [String]) throws -> Data {
        let source = try storeWithTasks(titles)
        return try KronosExportCodec.makeEncoder().encode(JSONExporter(store: source).makeEnvelope())
    }

    private func titles(_ store: TaskStore) -> [String] {
        store.allTasksIncludingDeleted().map(\.title).sorted()
    }

    @Test func replaceRefusesFileWithNoTasks() throws {
        let target = try storeWithTasks(["Alpha", "Beta"])
        let empty = try fileData(titles: [])

        #expect(throws: KronosImporter.ImportError.emptyEnvelope) {
            try KronosImporter(store: target).importData(empty, mode: .replace)
        }
        #expect(titles(target) == ["Alpha", "Beta"])

        // Control 1: a store with nothing in it has nothing to lose, so an empty file is accepted.
        let blank = try TaskStore(inMemory: true)
        let accepted = try KronosImporter(store: blank).importData(empty, mode: .replace)
        #expect(accepted.tasks == 0)

        // Control 2: the refusal belongs to Replace only. Merge of the same file is allowed and adds nothing.
        let merged = try KronosImporter(store: target).importData(empty, mode: .merge)
        #expect(merged.tasks == 0)
        #expect(titles(target) == ["Alpha", "Beta"])
    }

    @Test func safetyCopyRunsBeforeAnythingIsDeleted() throws {
        let target = try storeWithTasks(["Alpha", "Beta"])
        let file = try fileData(titles: ["Gamma", "Delta", "Epsilon"])
        var seenAtCopyTime: [String] = []
        var calls = 0

        let result = try KronosImporter(store: target).importData(file, mode: .replace) {
            calls += 1
            seenAtCopyTime = self.titles(target)
        }

        #expect(calls == 1)
        #expect(seenAtCopyTime == ["Alpha", "Beta"])
        #expect(result.tasks == 3)
        #expect(titles(target) == ["Delta", "Epsilon", "Gamma"])
    }

    @Test func mergeNeverTakesTheSafetyCopy() throws {
        let target = try storeWithTasks(["Alpha"])
        let file = try fileData(titles: ["Gamma"])
        var calls = 0
        _ = try KronosImporter(store: target).importData(file, mode: .merge) { calls += 1 }
        #expect(calls == 0)
        #expect(titles(target) == ["Alpha", "Gamma"])
    }

    @Test func failedSafetyCopyAbortsWithTheStoreUntouched() throws {
        struct DiskFull: Error {}
        let target = try storeWithTasks(["Alpha", "Beta"])
        let file = try fileData(titles: ["Gamma"])

        #expect(throws: KronosImporter.ImportError.safetyCopyFailed) {
            try KronosImporter(store: target).importData(file, mode: .replace) { throw DiskFull() }
        }
        #expect(titles(target) == ["Alpha", "Beta"])
    }

    @Test func failedSaveIsReportedAndRolledBack() throws {
        struct SaveError: Error {}
        let target = try storeWithTasks(["Alpha"])
        let source = try storeWithTasks(["Gamma", "Delta"])
        let envelope = JSONExporter(store: source).makeEnvelope()

        #expect(throws: KronosImporter.ImportError.saveFailed) {
            try KronosImporter(store: target).performImport(envelope, mode: .merge, beforeReplace: nil,
                                                            save: { throw SaveError() })
        }
        // Rolled back: memory shows what the disk has, not rows that were never written.
        #expect(titles(target) == ["Alpha"])
    }
}
