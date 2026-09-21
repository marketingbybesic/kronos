import Foundation

// The normative export/backup envelope. This is
// deliberately a SEPARATE format from `SeedFile` (Import/SeedCodec.swift),
// which is the loose Linear-import shape (tags/projectName-by-string).
// `SeedFile` stays exactly as it is — this file must not touch that import path.
//
// Wire-format rules (§10.1), all enforced by the types below:
//  - every id is a UUID, relationships referenced by id except owned subtasks
//  - days are "YYYY-MM-DD" strings, never raw Ints — `Day.iso` / `.parseISO`
//  - instants are ISO-8601 UTC
//  - nil is emitted as JSON `null`, never an omitted key — so every field
//    below is non-optional-with-explicit-`nil?` at the Swift level EXCEPT
//    where the field was added after v1 shipped and must stay `Optional` so
//    an older v1 file still decodes (`decodeIfPresent`).
//  - AppSettings, API keys and the MCP token are never exported.

/// The full backup/export payload. `version` stays 1: `effort`, project
/// `emoji`, the extended `KFilter` and the multi-key `sortJSON` are added
/// as optional keys, not a version bump, so every existing v1 file still
/// imports unchanged.
public struct KronosExportEnvelope: Codable, Equatable {
    public var format: String
    public var version: Int
    public var exportedAt: Date
    public var areas: [ExportedArea]
    public var projects: [ExportedProject]
    public var labels: [ExportedLabel]
    public var rules: [ExportedRule]
    public var savedViews: [ExportedSavedView]
    public var tasks: [ExportedTask]

    public init(format: String = "kronos", version: Int = 1, exportedAt: Date,
                areas: [ExportedArea] = [], projects: [ExportedProject] = [],
                labels: [ExportedLabel] = [], rules: [ExportedRule] = [],
                savedViews: [ExportedSavedView] = [], tasks: [ExportedTask] = []) {
        self.format = format
        self.version = version
        self.exportedAt = exportedAt
        self.areas = areas
        self.projects = projects
        self.labels = labels
        self.rules = rules
        self.savedViews = savedViews
        self.tasks = tasks
    }
}

public struct ExportedArea: Codable, Equatable {
    public var id: UUID
    public var name: String
    public var colorHex: String
    public var icon: String
    public var sortIndex: Double
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID, name: String, colorHex: String, icon: String,
                sortIndex: Double, createdAt: Date, updatedAt: Date) {
        self.id = id; self.name = name; self.colorHex = colorHex; self.icon = icon
        self.sortIndex = sortIndex; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

public struct ExportedProject: Codable, Equatable {
    public var id: UUID
    public var name: String
    public var colorHex: String
    /// Optional (§12.8) — a curated Icon-map name, or nil for the plain colour dot.
    /// `decodeIfPresent` so a file written before this field existed (key absent, or explicit
    /// `null`) still imports with icon nil.
    public var icon: String?
    /// Optional so an export written before this field existed still decodes.
    public var emoji: String?
    public var sortIndex: Double
    public var isArchived: Bool
    public var areaID: UUID?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID, name: String, colorHex: String, icon: String?, emoji: String?,
                sortIndex: Double, isArchived: Bool, areaID: UUID?,
                createdAt: Date, updatedAt: Date) {
        self.id = id; self.name = name; self.colorHex = colorHex; self.icon = icon
        self.emoji = emoji; self.sortIndex = sortIndex; self.isArchived = isArchived
        self.areaID = areaID; self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        colorHex = try c.decode(String.self, forKey: .colorHex)
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? nil
        emoji = try c.decodeIfPresent(String.self, forKey: .emoji) ?? nil
        sortIndex = try c.decode(Double.self, forKey: .sortIndex)
        isArchived = try c.decode(Bool.self, forKey: .isArchived)
        areaID = try c.decodeIfPresent(UUID.self, forKey: .areaID) ?? nil
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }
}

public struct ExportedLabel: Codable, Equatable {
    public var id: UUID
    public var name: String
    public var colorHex: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID, name: String, colorHex: String, createdAt: Date, updatedAt: Date) {
        self.id = id; self.name = name; self.colorHex = colorHex
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

public struct ExportedRule: Codable, Equatable {
    public var id: UUID
    public var text: String
    public var scope: Int
    public var source: Int
    public var isActive: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID, text: String, scope: Int, source: Int, isActive: Bool,
                createdAt: Date, updatedAt: Date) {
        self.id = id; self.text = text; self.scope = scope; self.source = source
        self.isActive = isActive; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

public struct ExportedSavedView: Codable, Equatable {
    public var id: UUID
    public var name: String
    public var icon: String
    public var sortIndex: Double
    public var filter: KFilter
    public var sortMode: Int
    /// The multi-key ordering. Optional so an older export, which carried no such field, still
    /// decodes to "no override" (falls back to `sortMode` exactly as `KSavedView.sortDescriptors`
    /// already does).
    public var sortDescriptors: [KSortDescriptor]?
    public var groupBy: Int
    public var showDone: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID, name: String, icon: String, sortIndex: Double, filter: KFilter,
                sortMode: Int, sortDescriptors: [KSortDescriptor]?, groupBy: Int,
                showDone: Bool, createdAt: Date, updatedAt: Date) {
        self.id = id; self.name = name; self.icon = icon; self.sortIndex = sortIndex
        self.filter = filter; self.sortMode = sortMode; self.sortDescriptors = sortDescriptors
        self.groupBy = groupBy; self.showDone = showDone
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        icon = try c.decode(String.self, forKey: .icon)
        sortIndex = try c.decode(Double.self, forKey: .sortIndex)
        filter = try c.decode(KFilter.self, forKey: .filter)
        sortMode = try c.decode(Int.self, forKey: .sortMode)
        sortDescriptors = try c.decodeIfPresent([KSortDescriptor].self, forKey: .sortDescriptors) ?? nil
        groupBy = try c.decode(Int.self, forKey: .groupBy)
        showDone = try c.decode(Bool.self, forKey: .showDone)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }
}

public struct ExportedSubtask: Codable, Equatable {
    public var id: UUID
    public var title: String
    public var isDone: Bool
    public var sortIndex: Double
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID, title: String, isDone: Bool, sortIndex: Double,
                createdAt: Date, updatedAt: Date) {
        self.id = id; self.title = title; self.isDone = isDone; self.sortIndex = sortIndex
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

public struct ExportedTask: Codable, Equatable {
    public var id: UUID
    public var title: String
    public var notes: String
    public var firstMove: String?
    public var status: Int
    public var priority: Int
    public var depth: Int
    /// Optional so an older v1 file still imports (`seedWithoutEffortKeyStillImports`);
    /// missing ⇒ `KEffort.none`.
    public var effort: Int?
    public var dread: Bool
    public var energyKind: Int?
    public var estimateMinutes: Int?
    public var dueDay: String?
    public var originalDueDay: String?
    public var completedAt: Date?
    public var sortIndex: Double
    public var ordoIndex: Double?
    /// Soft-deleted rows are exported too (§10.1 is silent; spec-3d resolves
    /// this in favour of a true backup: a purge should be recoverable from
    /// yesterday's file, so a deleted row exports with its `deletedAt` set
    /// rather than being dropped from the payload).
    public var deletedAt: Date?
    public var triagedAt: Date?
    public var triageModel: String?
    public var triageRationale: String?
    public var triageFeedback: String?
    public var triageReviewedAt: Date?
    public var needsTriage: Bool
    public var recurrenceRule: String?
    public var seriesID: UUID?
    public var calendarEventID: String?
    public var externalID: String?
    public var source: String?
    public var projectID: UUID?
    public var labelIDs: [UUID]
    public var subtasks: [ExportedSubtask]
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID, title: String, notes: String, firstMove: String?, status: Int,
                priority: Int, depth: Int, effort: Int?, dread: Bool, energyKind: Int?,
                estimateMinutes: Int?, dueDay: String?, originalDueDay: String?,
                completedAt: Date?, sortIndex: Double, ordoIndex: Double?, deletedAt: Date?,
                triagedAt: Date?, triageModel: String?, triageRationale: String?,
                triageFeedback: String?, triageReviewedAt: Date?, needsTriage: Bool,
                recurrenceRule: String?, seriesID: UUID?, calendarEventID: String?,
                externalID: String?, source: String?, projectID: UUID?, labelIDs: [UUID],
                subtasks: [ExportedSubtask], createdAt: Date, updatedAt: Date) {
        self.id = id; self.title = title; self.notes = notes; self.firstMove = firstMove
        self.status = status; self.priority = priority; self.depth = depth
        self.effort = effort; self.dread = dread; self.energyKind = energyKind
        self.estimateMinutes = estimateMinutes; self.dueDay = dueDay
        self.originalDueDay = originalDueDay; self.completedAt = completedAt
        self.sortIndex = sortIndex; self.ordoIndex = ordoIndex; self.deletedAt = deletedAt
        self.triagedAt = triagedAt; self.triageModel = triageModel
        self.triageRationale = triageRationale; self.triageFeedback = triageFeedback
        self.triageReviewedAt = triageReviewedAt; self.needsTriage = needsTriage
        self.recurrenceRule = recurrenceRule; self.seriesID = seriesID
        self.calendarEventID = calendarEventID; self.externalID = externalID
        self.source = source; self.projectID = projectID; self.labelIDs = labelIDs
        self.subtasks = subtasks; self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        notes = try c.decode(String.self, forKey: .notes)
        firstMove = try c.decodeIfPresent(String.self, forKey: .firstMove) ?? nil
        status = try c.decode(Int.self, forKey: .status)
        priority = try c.decode(Int.self, forKey: .priority)
        depth = try c.decode(Int.self, forKey: .depth)
        effort = try c.decodeIfPresent(Int.self, forKey: .effort) ?? nil
        dread = try c.decode(Bool.self, forKey: .dread)
        energyKind = try c.decodeIfPresent(Int.self, forKey: .energyKind) ?? nil
        estimateMinutes = try c.decodeIfPresent(Int.self, forKey: .estimateMinutes) ?? nil
        dueDay = try c.decodeIfPresent(String.self, forKey: .dueDay) ?? nil
        originalDueDay = try c.decodeIfPresent(String.self, forKey: .originalDueDay) ?? nil
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt) ?? nil
        sortIndex = try c.decode(Double.self, forKey: .sortIndex)
        ordoIndex = try c.decodeIfPresent(Double.self, forKey: .ordoIndex) ?? nil
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt) ?? nil
        triagedAt = try c.decodeIfPresent(Date.self, forKey: .triagedAt) ?? nil
        triageModel = try c.decodeIfPresent(String.self, forKey: .triageModel) ?? nil
        triageRationale = try c.decodeIfPresent(String.self, forKey: .triageRationale) ?? nil
        triageFeedback = try c.decodeIfPresent(String.self, forKey: .triageFeedback) ?? nil
        triageReviewedAt = try c.decodeIfPresent(Date.self, forKey: .triageReviewedAt) ?? nil
        needsTriage = try c.decode(Bool.self, forKey: .needsTriage)
        recurrenceRule = try c.decodeIfPresent(String.self, forKey: .recurrenceRule) ?? nil
        seriesID = try c.decodeIfPresent(UUID.self, forKey: .seriesID) ?? nil
        calendarEventID = try c.decodeIfPresent(String.self, forKey: .calendarEventID) ?? nil
        externalID = try c.decodeIfPresent(String.self, forKey: .externalID) ?? nil
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? nil
        projectID = try c.decodeIfPresent(UUID.self, forKey: .projectID) ?? nil
        labelIDs = try c.decodeIfPresent([UUID].self, forKey: .labelIDs) ?? []
        subtasks = try c.decodeIfPresent([ExportedSubtask].self, forKey: .subtasks) ?? []
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }
}

// MARK: - Shared codec configuration
//
// One encoder/decoder shape for export, backup and import alike (§10.2 "one
// serializer, not two"). `.sortedKeys` makes G12's byte-identical diff
// possible; `.prettyPrinted` is what the spec's example envelope shows and
// what a human reads when they open a backup file in a text editor.

public enum KronosExportCodec {
    public static func makeEncoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        return enc
    }

    public static func makeDecoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }
}
