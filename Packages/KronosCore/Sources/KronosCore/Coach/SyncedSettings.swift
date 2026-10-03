// Coach/SyncedSettings.swift — the settings split and the schema guard.
//
// Settings are split in two: a WHITELIST that follows the user across devices through the
// iCloud key-value store (`SettingsSync`, behind a flag until the account exists), and
// everything else, which stays on its device. A field that is not on the whitelist is never
// uploaded; a test enforces that every `CoachSettings` field is classified, so a new field
// cannot slip into either side unseen.
//
// `SchemaGuard` is the other half of the same store: the highest schema version any device has
// written is kept in the key-value store (and, from the app, in `KStoreMeta`); a build whose own
// schema is older than that minimum opens the store read-only instead of writing rows a newer
// build would misread.

import Foundation

// MARK: - Key-value seam

/// The slice of `NSUbiquitousKeyValueStore` this file needs, so tests run without iCloud.
public protocol SettingsKVS: AnyObject {
    func syncedData(forKey key: String) -> Data?
    func setSyncedData(_ data: Data?, forKey key: String)
    func syncedInt(forKey key: String) -> Int?
    func setSyncedInt(_ value: Int, forKey key: String)
}

extension NSUbiquitousKeyValueStore: SettingsKVS {
    public func syncedData(forKey key: String) -> Data? { data(forKey: key) }
    public func setSyncedData(_ data: Data?, forKey key: String) { set(data, forKey: key) }
    public func syncedInt(forKey key: String) -> Int? {
        object(forKey: key) == nil ? nil : Int(longLong(forKey: key))
    }
    public func setSyncedInt(_ value: Int, forKey key: String) { set(Int64(value), forKey: key) }
}

/// In-memory double for tests and for builds without an iCloud account.
public final class FixtureSettingsKVS: SettingsKVS {
    private var datas: [String: Data] = [:]
    private var ints: [String: Int] = [:]
    public init() {}
    public func syncedData(forKey key: String) -> Data? { datas[key] }
    public func setSyncedData(_ data: Data?, forKey key: String) { datas[key] = data }
    public func syncedInt(forKey key: String) -> Int? { ints[key] }
    public func setSyncedInt(_ value: Int, forKey key: String) { ints[key] = value }
}

// MARK: - The whitelist

/// The `CoachSettings` fields that sync, with the time they last changed.
public struct SyncedCoachSettings: Codable, Equatable, Sendable {
    public var v: Int = 1
    public var updatedAt: Date

    public var autoTriage: Bool
    public var triageMayFill: Set<CoachTriageField>
    public var blockCoachEnabled: Bool
    public var blockLeadMinutes: Int
    public var calendarKeywords: [UUID: [String]]
    public var learnedEventTitles: [String: UUID]
    public var defaultPresetByScope: [String: String]
    public var presets: [OrdoPreset]
    public var notesInboxFolder: String
    public var nowCardEnabled: Bool
    public var accentHex: String?
    public var density: String
    public var textSize: String

    /// Property names of `CoachSettings` that sync.
    public static let syncedFields: Set<String> = [
        "autoTriage", "triageMayFill", "blockCoachEnabled", "blockLeadMinutes", "calendarKeywords",
        "learnedEventTitles", "defaultPresetByScope", "presets", "notesInboxFolder", "nowCardEnabled",
        "accentHex", "density", "textSize",
    ]

    /// Property names that stay on the device: `v` is the blob version; `projectFolders` holds
    /// security-scoped bookmarks and Notes folder names that mean nothing on another device.
    public static let deviceLocalFields: Set<String> = ["v", "projectFolders"]

    public init(from s: CoachSettings, updatedAt: Date) {
        self.updatedAt = updatedAt
        autoTriage = s.autoTriage
        triageMayFill = s.triageMayFill
        blockCoachEnabled = s.blockCoachEnabled
        blockLeadMinutes = s.blockLeadMinutes
        calendarKeywords = s.calendarKeywords
        learnedEventTitles = s.learnedEventTitles
        defaultPresetByScope = s.defaultPresetByScope
        presets = s.presets
        notesInboxFolder = s.notesInboxFolder
        nowCardEnabled = s.nowCardEnabled
        accentHex = s.accentHex
        density = s.density
        textSize = s.textSize
    }

    /// `local` with the synced fields replaced; device-local fields are never touched.
    public func applied(to local: CoachSettings) -> CoachSettings {
        var s = local
        s.autoTriage = autoTriage
        s.triageMayFill = triageMayFill
        s.blockCoachEnabled = blockCoachEnabled
        s.blockLeadMinutes = blockLeadMinutes
        s.calendarKeywords = calendarKeywords
        s.learnedEventTitles = learnedEventTitles
        s.defaultPresetByScope = defaultPresetByScope
        s.presets = presets
        s.notesInboxFolder = notesInboxFolder
        s.nowCardEnabled = nowCardEnabled
        s.accentHex = accentHex
        s.density = density
        s.textSize = textSize
        return s
    }

    /// Same synced values, ignoring when they were written.
    func sameValues(as other: SyncedCoachSettings) -> Bool {
        var a = self, b = other
        a.updatedAt = .distantPast
        b.updatedAt = .distantPast
        return a == b
    }
}

// MARK: - Sync

/// Pushes the whitelist to the key-value store and pulls a newer remote copy. Whole blob,
/// newest `updatedAt` wins; a push of identical values writes nothing (no echo between devices).
@MainActor
public final class SettingsSync {
    public static let key = "kronos.settings.synced.v1"
    public static let flagKey = "kronos.sync.settings.enabled"

    private let kvs: any SettingsKVS
    private let isEnabled: () -> Bool

    /// - Parameter isEnabled: the flag. Defaults to off: nothing leaves the device until the
    ///   iCloud account exists and the app turns it on (`flag(in:)`).
    public init(kvs: any SettingsKVS, isEnabled: @escaping () -> Bool = { false }) {
        self.kvs = kvs
        self.isEnabled = isEnabled
    }

    public static func flag(in defaults: UserDefaults) -> () -> Bool {
        { defaults.bool(forKey: flagKey) }
    }

    private func remote() -> SyncedCoachSettings? {
        guard let data = kvs.syncedData(forKey: Self.key) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(SyncedCoachSettings.self, from: data)
    }

    /// Writes the whitelist when enabled and different from what is already there.
    /// Returns true when something was written.
    @discardableResult
    public func push(_ settings: CoachSettings, now: Date = Date()) -> Bool {
        guard isEnabled() else { return false }
        let mine = SyncedCoachSettings(from: settings, updatedAt: now)
        if let existing = remote(), existing.sameValues(as: mine) { return false }
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        guard let data = try? e.encode(mine) else { return false }
        kvs.setSyncedData(data, forKey: Self.key)
        return true
    }

    /// The remote copy when it is enabled, readable, and written after `localUpdatedAt`.
    public func newerRemote(than localUpdatedAt: Date?) -> SyncedCoachSettings? {
        guard isEnabled(), let r = remote() else { return nil }
        if let localUpdatedAt, r.updatedAt <= localUpdatedAt { return nil }
        return r
    }
}

// MARK: - Schema guard

public enum SchemaGuard {
    /// The schema major version this build writes (`KronosSchemaV2`).
    public static let currentBuildVersion = 2
    public static let kvsKey = "kronos.minSchemaVersion"

    public enum Mode: Equatable, Sendable {
        case readWrite
        /// This build is older than a schema some device already wrote: show a calm
        /// "update Kronos" line and write nothing.
        case readOnly(requires: Int)
    }

    /// `minimums` are the recorded minimums from every place they live (key-value store,
    /// `KStoreMeta`); missing ones are nil. The highest wins.
    public static func mode(build: Int = currentBuildVersion, minimums: [Int?]) -> Mode {
        let required = minimums.compactMap { $0 }.max() ?? 0
        return build < required ? .readOnly(requires: required) : .readWrite
    }

    public static func minimum(in kvs: any SettingsKVS) -> Int? {
        kvs.syncedInt(forKey: kvsKey)
    }

    /// Raises the recorded minimum; never lowers it (an old build must not undo the guard).
    @discardableResult
    public static func raiseMinimum(to version: Int, in kvs: any SettingsKVS) -> Bool {
        if let current = kvs.syncedInt(forKey: kvsKey), current >= version { return false }
        kvs.setSyncedInt(version, forKey: kvsKey)
        return true
    }
}
