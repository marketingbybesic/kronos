// Store-internal key/value rows (`KStoreMeta`): launch migration markers and other facts that
// belong to the STORE rather than to one device. A marker file under the store folder is
// per device: a second device sharing the same store through sync would have none and would
// run the migration again over data that already went through it. A marker row travels with
// the data.
//
// Several devices can write the same key before a sync settles, so readers take the newest
// `updatedAt` per key (ties: the larger value, so every device reads the same answer) and the
// dedupe sweep removes the older rows.

import Foundation
import SwiftData

/// The keys Kronos stores in `KStoreMeta`.
public enum StoreMetaKey {
    /// Steps became child tasks (the launch conversion, now inside the V1 -> V2 stage).
    public static let subtasksToTasks = "migration.subtasksToTasks.v1"
    /// The retired undated-to-Someday catch-up (marker only).
    public static let undatedSomeday = "migration.undatedSomeday.v1"
    /// The corrupt-context-link cleanup (`TaskStore.stripCorruptContextLinkLines`), marker only.
    public static let corruptContextLinkLines = "migration.corruptContextLinkLines.v1"
    /// The highest schema version any build has written to this store. An older build reads it
    /// at open and stays read-only (`SchemaGuard`, with the key-value store copy).
    public static let minSchemaVersion = "schema.minVersion"
}

@MainActor
extension TaskStore {

    /// Every row stored under `key`.
    func metaRows(_ key: String) -> [KStoreMeta] {
        let d = FetchDescriptor<KStoreMeta>(predicate: #Predicate { $0.key == key })
        return (try? context.fetch(d)) ?? []
    }

    /// The value stored under `key`, or nil. With several rows the newest wins.
    public func metaValue(_ key: String) -> String? {
        StoreMetaResolution.newest(metaRows(key))?.value
    }

    /// Store `value` under `key` (no undo: bookkeeping, not a user edit). Rewrites the newest
    /// row when one exists, so repeated writes never pile up rows.
    public func setMeta(_ key: String, _ value: String, now: Date = Date()) {
        if let row = StoreMetaResolution.newest(metaRows(key)) {
            guard row.value != value else { return }
            row.value = value
            row.updatedAt = now
        } else {
            context.insert(KStoreMeta(key: key, value: value, updatedAt: now))
        }
        saveContext()
    }

    /// The minimum schema version recorded in this store, or nil when none is. Unlike other
    /// keys the HIGHEST row wins: an older device writing later must never lower it.
    public var storeMinimumSchemaVersion: Int? {
        metaRows(StoreMetaKey.minSchemaVersion).compactMap { Int($0.value) }.max()
    }

    /// Record that this store holds data of schema `version`. Only ever raises the value (an
    /// older build must not lower the guard). True when it wrote. Call after the open decided
    /// the store is writable.
    @discardableResult
    public func raiseStoreMinimumSchemaVersion(to version: Int, now: Date = Date()) -> Bool {
        if let current = storeMinimumSchemaVersion, current >= version { return false }
        setMeta(StoreMetaKey.minSchemaVersion, String(version), now: now)
        return true
    }
}

enum StoreMetaResolution {
    /// The row a reader trusts: newest `updatedAt`, then the larger value, then the larger id.
    static func newest(_ rows: [KStoreMeta]) -> KStoreMeta? {
        rows.max { a, b in
            if a.updatedAt != b.updatedAt { return a.updatedAt < b.updatedAt }
            if a.value != b.value { return a.value < b.value }
            return a.id.uuidString < b.id.uuidString
        }
    }
}

/// Whether a one-time launch migration runs on this store.
public enum MigrationGate {
    public enum Decision: Equatable, Sendable {
        /// Never marked anywhere, sync off: run it, then mark the store.
        case run
        /// The store already carries the marker.
        case alreadyDone
        /// This device ran it before markers moved into the store (the marker FILE exists):
        /// record the marker in the store, run nothing.
        case adoptFileMarker
        /// The store is synced: a device never migrates shared data on its own, and writes no
        /// marker either (migrations finish on the Mac before sync is turned on).
        case skipSyncEnabled
    }

    public static func decide(storeMarked: Bool, fileMarked: Bool, syncEnabled: Bool) -> Decision {
        if syncEnabled { return .skipSyncEnabled }
        if storeMarked { return .alreadyDone }
        if fileMarked { return .adoptFileMarker }
        return .run
    }
}

/// First-launch seeding (the optional import of a seed file into an empty store).
public enum SeedPolicy {
    /// A synced device must not seed before the first import from iCloud has finished: an
    /// empty store at that moment only means the data has not arrived yet, and seeding then
    /// doubles everything once it does. Without sync an empty store may be seeded at once.
    /// The caller still checks that the store is empty.
    public static func shouldSeed(syncEnabled: Bool, importDone: Bool) -> Bool {
        !syncEnabled || importDone
    }
}
