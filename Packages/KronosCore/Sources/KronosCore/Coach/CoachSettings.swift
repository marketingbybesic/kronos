// Coach/CoachSettings.swift — settings persistence for the coach features:
// block-coach lead time, calendar keywords, notes inbox folder, default
// preset per scope.
//
// One JSON blob in an injected `UserDefaults`, versioned so a future field
// can be added without breaking a user's existing preferences. Tests inject
// an isolated suite (`UserDefaults(suiteName:)`) so nothing here ever touches
// the app's real defaults domain — see `CoachSettingsStore.init`.

import Foundation

/// One field `NeighbourTriage` / the AI triage result can fill on a task.
/// Deliberately a Core-local enum rather than importing an AI-layer type,
/// so this file has no dependency on `Contracts/AI*.swift`. If the AI
/// layer's DTO needs a matching set, the two are mapped at the boundary.
public enum CoachTriageField: String, Codable, CaseIterable, Sendable {
    case priority, effort, project, depth, deadline, firstMove
}

/// Everything the coach behaviour needs, editable from Settings (feature G).
/// Codable and versioned: `v` lets a future migration recognise an old blob
/// instead of guessing from field presence alone.
public struct CoachSettings: Codable, Equatable, Sendable {
    public var v: Int = 1

    // MARK: Triage (feature B wiring)
    public var autoTriage: Bool = true
    public var triageMayFill: Set<CoachTriageField> = Set(CoachTriageField.allCases)

    // MARK: Block coach (feature C)
    public var blockCoachEnabled: Bool = true
    public var blockLeadMinutes: Int = 5
    /// Project id -> keywords that identify its calendar blocks. An empty (or
    /// absent) array means "use the project's own name" — `BlockCoach` and
    /// `OsaScriptNotesBridge` callers apply that fallback, this type just
    /// stores the override.
    public var calendarKeywords: [UUID: [String]] = [:]
    /// Folded event title -> project id, learned automatically whenever the
    /// user answers "Switch" for an event `BlockCoach` matched, or picks a
    /// project explicitly for one it could not match
    /// (`BlockCoach.unmatchedUpcomingEvents`). Checked before any keyword
    /// rule, since it is a direct record of what the user actually chose
    /// for this exact event title. Use `learn(eventTitle:projectID:)` to
    /// write to it — do not fold titles by hand at the call site.
    public var learnedEventTitles: [String: UUID] = [:]

    // MARK: Ordo presets (feature E)
    /// Scope storage key (`ListScope.storageKey` in the app) -> preset id.
    public var defaultPresetByScope: [String: String] = [:]
    public var presets: [OrdoPreset] = OrdoPreset.builtIns

    // MARK: Notes (feature F)
    public var notesInboxFolder: String = "Kronos"
    /// Project id -> the context folders/links attached to that project
    /// (an Apple Notes folder, a bookmarked Finder folder, or both).
    public var projectFolders: [UUID: [ProjectFolderLink]] = [:]

    // MARK: Appearance passthrough (feature G/H — plain values only; the
    // design-system leaf resolves them to actual colours/metrics)
    public var nowCardEnabled: Bool = true
    public var accentHex: String? = nil
    public var density: String = "regular"
    public var textSize: String = "M"

    public init() {}

    /// Records that `eventTitle` should map to `projectID` from now on —
    /// called when the user answers "Switch" for a `BlockCoach` suggestion,
    /// or explicitly picks a project for an event `BlockCoach` could not
    /// match. Folds the title so future exact-title lookups are
    /// case/diacritic-insensitive, matching every other title comparison in
    /// Core (`KTextFold`). Overwrites any previous mapping for that title —
    /// the latest answer always wins.
    public mutating func learn(eventTitle: String, projectID: UUID) {
        learnedEventTitles[KTextFold.fold(eventTitle)] = projectID
    }
}

/// One context folder/link attached to a project: either a named Apple
/// Notes folder, or a bookmarked Finder folder. `Data` bookmarks (not raw
/// paths) survive the user moving or
/// renaming the folder, per the standard security-scoped bookmark pattern —
/// resolving the bookmark is the app's job (needs `NSOpenPanel`/URL APIs
/// this pure Core type does not depend on); this type only stores it.
public struct ProjectFolderLink: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case appleNotesFolder
        case finderFolder
    }

    public var id: UUID
    public var kind: Kind
    /// The Notes folder name (`.appleNotesFolder`), or nil for a Finder link.
    public var notesFolderName: String?
    /// The Finder folder's security-scoped bookmark (`.finderFolder`), or nil
    /// for a Notes link.
    public var folderBookmark: Data?
    /// A human-readable path/name for display without resolving the
    /// bookmark — e.g. the sidebar row's subtitle.
    public var displayPath: String

    public init(id: UUID = UUID(), kind: Kind, notesFolderName: String? = nil,
                folderBookmark: Data? = nil, displayPath: String) {
        self.id = id
        self.kind = kind
        self.notesFolderName = notesFolderName
        self.folderBookmark = folderBookmark
        self.displayPath = displayPath
    }

    public static func appleNotes(folderName: String) -> ProjectFolderLink {
        ProjectFolderLink(kind: .appleNotesFolder, notesFolderName: folderName, displayPath: folderName)
    }

    public static func finder(bookmark: Data, displayPath: String) -> ProjectFolderLink {
        ProjectFolderLink(kind: .finderFolder, folderBookmark: bookmark, displayPath: displayPath)
    }
}

/// Loads/saves `CoachSettings` as one JSON value under a single key, and
/// notifies observers on save so a settings screen and a menu-bar popover
/// stay in sync without polling.
@MainActor
public final class CoachSettingsStore {
    private let defaults: UserDefaults
    private let key: String

    public static let didChangeNotification = Notification.Name("kronosCoachSettingsDidChange")

    /// - Parameters:
    ///   - defaults: injected so tests use an isolated suite rather than
    ///     `UserDefaults.standard`.
    ///   - key: overridable only for tests that need two independent stores
    ///     in the same suite.
    public init(defaults: UserDefaults, key: String = "kronos.coach.settings.v1") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> CoachSettings {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(CoachSettings.self, from: data) else {
            return CoachSettings()
        }
        return decoded
    }

    public func save(_ settings: CoachSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}
