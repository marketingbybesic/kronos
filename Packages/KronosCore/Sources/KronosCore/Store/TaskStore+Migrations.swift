// Launch-time housekeeping that runs against the store once it is open.
//
// Extensions in a separate file cannot see `private` members, so this relies on the same
// internal (not private) plumbing TaskStore+NoUndo.swift already uses: `isMachineWrite`,
// `saveContext`.

import Foundation

@MainActor
extension TaskStore {

    /// The result of one launch-time run of the retired undated-to-Someday catch-up.
    public struct UndatedSomedayMigrationResult: Equatable, Sendable {
        public let moved: Int
    }

    /// Removes the junk lines a broken 28.09.2026 build wrote into task notes on every drop
    /// (`ContextLink.corruptLines`). Idempotent and cheap, so it runs every launch with no
    /// marker; touches only notes that contain them, never `updatedAt`, one save, no undo.
    @discardableResult
    public static func stripCorruptContextLinkLines(store: TaskStore) -> Int {
        let fixes = store.allTasksIncludingSubtasks().compactMap { t in ContextLink.strippingCorruptLines(t.notes).map { (t, $0) } }
        guard !fixes.isEmpty else { return 0 }
        let wasMachine = store.isMachineWrite
        store.isMachineWrite = true
        for (t, clean) in fixes { t.notes = clean }
        store.isMachineWrite = wasMachine
        store.saveContext()
        return fixes.count
    }
}

// MARK: - Launch-time entry point (marker file only, called once from AppDelegate)

/// This used to move every open undated `.todo` to Someday. An undated task now belongs in the
/// Inbox as an open todo (`ListScopeDefaults`), so the catch-up must not run any more: on a store
/// that never ran it, it would empty the Inbox into Someday. It stays as a marker-only no-op so
/// the launch call and the marker folder keep their shape, and rows already in Someday are left
/// exactly where they are.
@MainActor
public enum UndatedSomedayMigration {
    /// Relative to `KronosStore.containerDirectory()`, the same KRONOS_STORE_DIR-hermetic root
    /// every store/backup path uses.
    static let markerRelativePath = "migrations/undatedSomeday.v1"

    /// Writes the marker the first time and returns `moved == 0`; every later call returns nil.
    /// Changes no task and takes no backup. The marker lives in the store
    /// (`StoreMetaKey.undatedSomeday`); an earlier build's marker FILE is honoured (copied into
    /// the store, nothing runs), and a synced store is left alone entirely (`MigrationGate`).
    @discardableResult
    public static func runIfNeeded(store: TaskStore, now: Date = Date(),
                                   syncEnabled: Bool = KronosStore.isSyncEnabled) -> TaskStore.UndatedSomedayMigrationResult? {
        runIfNeeded(store: store, marker: KronosStore.containerDirectory().appendingPathComponent(markerRelativePath),
                    syncEnabled: syncEnabled)
    }

    /// As above with an explicit marker file (tests).
    @discardableResult
    static func runIfNeeded(store: TaskStore, marker: URL, syncEnabled: Bool) -> TaskStore.UndatedSomedayMigrationResult? {
        let key = StoreMetaKey.undatedSomeday
        switch MigrationGate.decide(storeMarked: store.metaValue(key) != nil,
                                    fileMarked: FileManager.default.fileExists(atPath: marker.path),
                                    syncEnabled: syncEnabled) {
        case .skipSyncEnabled, .alreadyDone:
            return nil
        case .adoptFileMarker:
            store.setMeta(key, "1")
            return nil
        case .run:
            try? FileManager.default.createDirectory(at: marker.deletingLastPathComponent(),
                                                      withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: marker.path, contents: Data("1".utf8))
            store.setMeta(key, "1")
            return TaskStore.UndatedSomedayMigrationResult(moved: 0)
        }
    }
}
