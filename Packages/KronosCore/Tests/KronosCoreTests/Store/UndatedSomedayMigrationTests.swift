import Foundation
import Testing
@testable import KronosCore

/// The undated-to-Someday catch-up is retired: an undated task is an open todo in the Inbox, so
/// the launch call only writes its marker and must leave every row exactly as it is.
@MainActor
@Suite struct UndatedSomedayMigrationTests {

    private func scratchDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kronos-undated-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Open undated todos stay todos, Someday rows stay in Someday, dated rows are untouched, no
    /// undo step is pushed, and the first run reports moved == 0.
    @Test func firstRunWritesTheMarkerAndMovesNothing() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        setenv("KRONOS_STORE_DIR", dir.path, 1)
        defer { unsetenv("KRONOS_STORE_DIR") }

        let store = try TaskStore(inMemory: true)
        for i in 0..<5 { store.createNoUndo(title: "Undated todo \(i)", status: .todo, dueDay: nil) }
        for i in 0..<2 { store.createNoUndo(title: "Already someday \(i)", status: .someday, dueDay: nil) }
        store.createNoUndo(title: "Dated todo", status: .todo, dueDay: Day.today() + 3)
        let depth = store.undoDepth

        let result = UndatedSomedayMigration.runIfNeeded(store: store)
        #expect(result == TaskStore.UndatedSomedayMigrationResult(moved: 0))

        let all = store.allTasks()
        #expect(all.filter { $0.title.hasPrefix("Undated todo") }.count == 5)
        #expect(all.filter { $0.title.hasPrefix("Undated todo") }.allSatisfy { $0.status == .todo })
        #expect(all.filter { $0.title.hasPrefix("Already someday") }.allSatisfy { $0.status == .someday })
        #expect(all.first { $0.title == "Dated todo" }?.status == .todo)
        #expect(store.undoDepth == depth)
        let marker = dir.appendingPathComponent(UndatedSomedayMigration.markerRelativePath)
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    /// No backup file either: nothing is mutated, so there is nothing to protect.
    @Test func firstRunWritesNoBackup() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        setenv("KRONOS_STORE_DIR", dir.path, 1)
        defer { unsetenv("KRONOS_STORE_DIR") }

        let store = try TaskStore(inMemory: true)
        store.createNoUndo(title: "Undated todo", status: .todo, dueDay: nil)
        _ = UndatedSomedayMigration.runIfNeeded(store: store)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("Backups").path))
    }

    /// Second call on the same directory: the marker exists, so it returns nil and still touches nothing.
    @Test func secondRunIsANilNoOp() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        setenv("KRONOS_STORE_DIR", dir.path, 1)
        defer { unsetenv("KRONOS_STORE_DIR") }

        let store = try TaskStore(inMemory: true)
        #expect(UndatedSomedayMigration.runIfNeeded(store: store)?.moved == 0)
        store.createNoUndo(title: "Added later", status: .todo, dueDay: nil)
        #expect(UndatedSomedayMigration.runIfNeeded(store: store) == nil)
        #expect(store.allTasks().first { $0.title == "Added later" }?.status == .todo)
    }
}
