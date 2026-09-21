// Part of the frozen contract surface. See Contracts.swift.
//
// Runtime helpers that are contract, not model: the reference orderings, the
// schema version, where the store file lives, the decided undo window, the
// menu-bar focus value and the notification names. Split out of
// Contracts.swift to keep every contract file under 500 lines.

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
        let ad = a.dueDay ?? Int.max
        let bd = b.dueDay ?? Int.max
        if ad != bd { return ad < bd }
        if a.priorityRaw != b.priorityRaw { return a.priorityRaw > b.priorityRaw }
        if a.sortIndex != b.sortIndex { return a.sortIndex < b.sortIndex }
        return a.id.uuidString < b.id.uuidString
    }
}

// MARK: - Schema versioning (§10.3)

public enum KronosSchemaV1: VersionedSchema {
    public static var versionIdentifier = Schema.Version(1, 0, 0)
    public static var models: [any PersistentModel.Type] {
        [KArea.self, KProject.self, KLabel.self, KTask.self,
         KSubtask.self, KRule.self, KSavedView.self]
    }
}

public enum KronosMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [KronosSchemaV1.self] }
    public static var stages: [MigrationStage] { [] }
}

// MARK: - KronosStore (tech-stack §1.3)

public enum KronosStore {
    /// The one place the store URL is decided.
    /// Alpha (unsandboxed, no Team ID) → ~/Library/Application Support/Kronos/Kronos.store
    public static func storeURL() -> URL {
        let dir = containerDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Kronos.store")
    }

    /// The optional first-run seed lives NEXT TO the store (Application Support), never in
    /// ~/Downloads or ~/Documents: reading those shows a macOS privacy prompt that blocked the
    /// main thread at launch. The seed can hold a user's real tasks, so it is copied there at
    /// install time and is never bundled into the app.
    public static func seedURL() -> URL {
        containerDirectory().appendingPathComponent("kronos-seed.json")
    }

    public static func containerDirectory() -> URL {
        // KRONOS_STORE_DIR points the app at another directory: used to try a migration on a COPY
        // of the real store and to hand-test without touching the user's real data.
        if let override = ProcessInfo.processInfo.environment["KRONOS_STORE_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Kronos", isDirectory: true)
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
