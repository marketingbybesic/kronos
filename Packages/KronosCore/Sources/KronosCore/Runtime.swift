// Part of the frozen contract surface. See Contracts.swift.
//
// Runtime helpers that are contract: the reference orderings, the schema
// versions and migration plans (plus the small models new in schema V2),
// where the store file lives, the decided undo window, the menu-bar focus
// value and the notification names. Split out of Contracts.swift to keep
// every contract file under 500 lines.

import Foundation
import SwiftData

// MARK: - Ordering (§5.3, one reference implementation)

public enum Ordering {
    public static func manual(_ a: KTask, _ b: KTask) -> Bool {
        if a.sortIndex != b.sortIndex { return a.sortIndex < b.sortIndex }
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.id.uuidString < b.id.uuidString
    }

    public static func ordo(_ a: KTask, _ b: KTask) -> Bool {
        let ai = a.ordoIndex ?? .greatestFiniteMagnitude
        let bi = b.ordoIndex ?? .greatestFiniteMagnitude
        if ai != bi { return ai < bi }
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
        return a.id.uuidString < b.id.uuidString
    }

    public static func priorityThenDue(_ a: KTask, _ b: KTask) -> Bool {
        let ad = a.effectiveDue ?? Int.max
        let bd = b.effectiveDue ?? Int.max
        if ad != bd { return ad < bd }
        if a.priorityRaw != b.priorityRaw { return a.priorityRaw > b.priorityRaw }
        if a.sortIndex != b.sortIndex { return a.sortIndex < b.sortIndex }
        return a.id.uuidString < b.id.uuidString
    }
}

// MARK: - Schema versioning (§10.3)
//
// V1 is frozen in Store/SchemaV1Frozen.swift (nested copies, never edited). V2 is the set of
// top-level models below and in Contracts.swift / Filtering.swift. V2 carries every field the
// planned work needs, so no V3 is due before a CloudKit deploy. The V1 -> V2 stage
// (Store/SchemaV2Stage.swift) turns any leftover step rows into child tasks before the step
// table is dropped.

/// The main, syncable schema: what `TaskStore` opens. Every attribute is optional or defaulted,
/// nothing is unique, every relationship is optional with an inverse (CloudKit rules).
public enum KronosSchemaV2: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    public static var models: [any PersistentModel.Type] {
        [KArea.self, KProject.self, KLabel.self, KTask.self,
         KRule.self, KSavedView.self, KStoreMeta.self, KSession.self, KAttachment.self]
    }
}

public enum KronosMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [KronosSchemaV1.self, KronosSchemaV2.self] }
    public static var stages: [MigrationStage] { [KronosSchemaV2Stage.v1ToV2] }
}

/// The device-local schema (`<store dir>/Kronos-local.store`, never synced): agent identities
/// and the activity log. Its own container (`KronosLocalStore`), never part of the main schema,
/// and no relationships to main models (ids are plain UUID scalars).
public enum KronosLocalSchemaV1: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    public static var models: [any PersistentModel.Type] { [KAgent.self, KActivity.self] }
}

public enum KronosLocalMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [KronosLocalSchemaV1.self] }
    public static var stages: [MigrationStage] { [] }
}

// MARK: - Models new in schema V2

/// Store-internal key/value rows: migration markers and the schema version, so they travel with
/// the store instead of living in per-device files. Several devices can write the same key
/// before a sync settles; readers keep the newest `updatedAt` per key.
@Model
public final class KStoreMeta {
    public var id: UUID = UUID()
    public var key: String = ""
    public var value: String = ""
    public var updatedAt: Date = Date()

    public init(key: String, value: String, updatedAt: Date = Date()) {
        self.key = key
        self.value = value
        self.updatedAt = updatedAt
    }
}

/// One timed work session (pomodoro, interval, flow, time block). Defined now so the store needs
/// no new version when the Watch timers ship; nothing writes it yet.
@Model
public final class KSession {
    public var id: UUID = UUID()
    public var taskID: UUID? = nil
    /// 0 pomodoro, 1 interval, 2 flow, 3 block.
    public var kindRaw: Int = 0
    public var plannedMinutes: Int = 0
    public var startedAt: Date = Date()
    public var endedAt: Date? = nil
    /// The phase plan and progress as JSON.
    public var phaseJSON: String = ""
    /// Which device ran it.
    public var device: String = ""
    /// 0 running, 1 done, 2 stopped.
    public var outcomeRaw: Int = 0
    public var flowSelfReport: Int? = nil

    public init(taskID: UUID? = nil, kindRaw: Int = 0, plannedMinutes: Int = 0, startedAt: Date = Date()) {
        self.taskID = taskID
        self.kindRaw = kindRaw
        self.plannedMinutes = plannedMinutes
        self.startedAt = startedAt
    }
}

/// A link, file or image attached to a task. Defined now (unused until attachments ship) so the
/// store needs no new version for it. Large payloads live outside the SQLite file.
@Model
public final class KAttachment {
    public var id: UUID = UUID()
    /// 0 link, 1 file, 2 image.
    public var kindRaw: Int = 0
    public var title: String = ""
    public var url: String? = nil
    @Attribute(.externalStorage)
    public var data: Data? = nil
    public var byteCount: Int = 0
    public var createdAt: Date = Date()

    public var task: KTask?

    public init(kindRaw: Int = 0, title: String = "", url: String? = nil) {
        self.kindRaw = kindRaw
        self.title = title
        self.url = url
    }
}

// MARK: - Store location

/// The folder that holds the store, its backups, markers and lock file, decided from plain
/// inputs so every platform's rule can be tested on any machine.
public struct KronosStoreLocation: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// `KRONOS_STORE_DIR` (migration checks on a copy, hermetic test runs).
        case override
        /// The App Group container shared with widgets and extensions.
        case appGroup
        /// `<Application Support>/<Kronos | Kronos Demo>`.
        case applicationSupport
    }

    public let directory: URL
    public let kind: Kind

    public init(directory: URL, kind: Kind) {
        self.directory = directory
        self.kind = kind
    }

    /// An explicit override wins; then the App Group container when the platform provides one
    /// (`appGroupContainer` is nil on the Mac and without the entitlement); else Application
    /// Support. The demo build always gets its own folder name.
    public static func resolve(environment: [String: String], bundleID: String?,
                               appGroupContainer: URL?, applicationSupport: URL) -> KronosStoreLocation {
        if let override = environment["KRONOS_STORE_DIR"], !override.isEmpty {
            return KronosStoreLocation(directory: URL(fileURLWithPath: override, isDirectory: true), kind: .override)
        }
        let folder = KronosStore.folderName(bundleID: bundleID)
        if let group = appGroupContainer {
            return KronosStoreLocation(directory: group.appendingPathComponent(folder, isDirectory: true), kind: .appGroup)
        }
        return KronosStoreLocation(directory: applicationSupport.appendingPathComponent(folder, isDirectory: true),
                                   kind: .applicationSupport)
    }
}

// MARK: - KronosStore (tech-stack §1.3)

public enum KronosStore {
    /// The one place the store URL is decided.
    /// Alpha (unsandboxed, no Team ID) → ~/Library/Application Support/Kronos/Kronos.store
    public static func storeURL() -> URL {
        let dir = containerDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return storeURL(in: dir)
    }

    /// The optional first-run seed lives NEXT TO the store (Application Support), never in
    /// ~/Downloads or ~/Documents: reading those shows a macOS privacy prompt that blocked the
    /// main thread at launch. The seed can hold a user's real tasks, so it is copied there at
    /// install time and is never bundled into the app.
    public static func seedURL() -> URL {
        containerDirectory().appendingPathComponent("kronos-seed.json")
    }

    public static func containerDirectory() -> URL { location().directory }

    /// The store file inside `directory` (tests and tools that open a store somewhere else).
    public static func storeURL(in directory: URL) -> URL {
        directory.appendingPathComponent("Kronos.store")
    }

    /// The App Group shared by the app, its widgets and extensions on iPhone, iPad, Watch and
    /// Vision Pro. Only read off the Mac (see `location()`).
    public static let appGroupIdentifier = "group.com.besic.kronos"

    /// Where the store folder is for this process, from the live environment.
    public static func location() -> KronosStoreLocation {
        let env = ProcessInfo.processInfo.environment
        #if os(macOS)
        // The Mac keeps its folder under Application Support. Moving it into the group
        // container is a one-time file move with a backup, not a side effect of a lookup, and
        // `containerURL(forSecurityApplicationGroupIdentifier:)` answers even without the
        // entitlement on an unsandboxed Mac, so it is never asked here.
        let group: URL? = nil
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        #else
        let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        #endif
        return KronosStoreLocation.resolve(environment: env, bundleID: Bundle.main.bundleIdentifier,
                                           appGroupContainer: group, applicationSupport: support)
    }

    /// Whether the main store mirrors to iCloud. Off until the iCloud entitlement exists; it
    /// flips together with `cloudKitDatabaseSetting`. Launch-time migrations and seeding read it
    /// (a synced store is never migrated or seeded by a device on its own).
    public static var isSyncEnabled: Bool { false }

    /// The demo build (bundle id `com.besic.kronos.demo`) gets its OWN folder: the path was
    /// hardcoded, so the demo opened — and migrated — the user's real store.
    static func folderName(bundleID: String?) -> String {
        bundleID?.hasSuffix(".demo") == true ? "Kronos Demo" : "Kronos"
    }

    /// The single place that decides whether `ModelConfiguration` mirrors to
    /// CloudKit. Left at `.none` until an iCloud entitlement exists: SwiftData's
    /// own default for an unspecified `cloudKitDatabase:` argument is
    /// `.automatic`, which starts attempting a CloudKit sync the moment the
    /// entitlement appears, whether or not sync work has actually shipped.
    /// Flipping this later is meant to be a one-line change: read a build
    /// setting here instead of returning `.none`, nothing else moves.
    public static var cloudKitDatabaseSetting: ModelConfiguration.CloudKitDatabase { .none }
}

// MARK: - Timing

public enum KronosTiming {
    /// The undo window, everywhere. SPEC §12.4 open item 2 is decided: 5 s,
    /// not 3 s, so one number governs every undo affordance — the inline
    /// completion undo, the menu-bar completion, and Cmd-Z's toast alike.
    public static let undoWindowSeconds: TimeInterval = 5
}

// MARK: - OrdoFocus

/// What the menu-bar item shows: the FIRST task of the currently open list,
/// under that list's current filter and sort.
///
/// A menu-bar item, not a floating Bar, and with it ORDO is not a hand-curated queue: focus is
/// derived — the UI owns the list, computes its first row, and publishes this value; the menu
/// bar only renders it. Nothing here reads or writes `ordoIndex`.
///
/// A value type on purpose — it crosses from the UI to the menu bar through
/// a notification, so it must be `Sendable` and carry everything the menu
/// bar needs without touching the store.
public struct OrdoFocus: Equatable, Sendable {
    /// nil when the list is empty; the menu bar then shows its empty state.
    public let taskID: UUID?
    public let title: String
    public let firstMove: String?
    /// The list this focus came from, e.g. "Today" or a saved view's name.
    public let listName: String
    /// How many rows remain in the list after this one. Never rendered as a
    /// badge or a count of what is late — no pressure copy (SPEC §3.9).
    public let remaining: Int

    public init(taskID: UUID?,
                title: String,
                firstMove: String? = nil,
                listName: String,
                remaining: Int = 0) {
        self.taskID    = taskID
        self.title     = title
        self.firstMove = firstMove
        self.listName  = listName
        self.remaining = remaining
    }

    /// The empty-list focus for `listName`.
    public static func empty(listName: String) -> OrdoFocus {
        OrdoFocus(taskID: nil, title: "", firstMove: nil,
                  listName: listName, remaining: 0)
    }

    public var isEmpty: Bool { taskID == nil }
}

// MARK: - Notifications

public extension Notification.Name {
    static let kronosDidCompleteFromBar       = Notification.Name("kronosDidCompleteFromBar")
    static let kronosStoreDidChangeExternally = Notification.Name("kronosStoreDidChangeExternally")
    /// A person (not a machine write) completed a task / ticked a subtask. The app plays its cue.
    /// A task was created through `TaskStoring.create` (not an import, not a recurrence spawn).
    static let kronosTaskDidCreate            = Notification.Name("kronosTaskDidCreate")
    static let kronosTaskDidComplete          = Notification.Name("kronosTaskDidComplete")
    static let kronosSubtaskDidComplete       = Notification.Name("kronosSubtaskDidComplete")
    static let kronosDayDidChange             = Notification.Name("kronosDayDidChange")
    /// Posted by the UI when the open list's first row changes. The menu-bar
    /// item observes this and re-renders from the `OrdoFocus` in the payload.
    static let kronosOrdoFocusDidChange       = Notification.Name("kronosOrdoFocusDidChange")
}
