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
    /// w22e: task templates (app-owned JSON file). Optional: older builds ignore the key, older
    /// files simply lack it.
    public var templates: [TaskTemplate]?

    public init(format: String = "kronos", version: Int = 1, exportedAt: Date,
                areas: [ExportedArea] = [], projects: [ExportedProject] = [],
                labels: [ExportedLabel] = [], rules: [ExportedRule] = [],
                savedViews: [ExportedSavedView] = [], tasks: [ExportedTask] = [],
                templates: [TaskTemplate]? = nil) {
        self.templates = templates
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
    /// The subtask's attachment lines. Optional so a file written before subtasks had notes
    /// still imports (missing ⇒ "").
    public var notes: String?
    /// O15: optional due day for subtasks (additive field).
    public var dueDay: String?
    /// O15: optional priority for subtasks (additive field).
    public var priority: Int?

    public init(id: UUID, title: String, isDone: Bool, sortIndex: Double,
                createdAt: Date, updatedAt: Date, notes: String? = nil,
                dueDay: String? = nil, priority: Int? = nil) {
        self.id = id; self.title = title; self.isDone = isDone; self.sortIndex = sortIndex
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.notes = notes
        self.dueDay = dueDay; self.priority = priority
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
    /// Previous format: steps inside their task. Current exports write steps as tasks with
    /// `parentID`, so this is empty unless a store still holds unmigrated legacy rows; the
    /// importer reads both.
    public var subtasks: [ExportedSubtask]
    /// The parent task of a subtask (one level). Optional: absent for a top-level task and in
    /// every file written before subtasks became tasks.
    public var parentID: UUID?
    /// w22e: ids this task waits on. Optional so an older v1 file still imports (missing = none)
    /// and a task with no dependencies exports byte-identically to before.
    public var waitsOn: [UUID]?
    /// The day the person means to do the task. Optional: absent when unplanned and in every file
    /// written before planning existed, so an unplanned task exports exactly as it used to.
    public var plannedDay: String?
    /// How many days an unfinished deadline carried. Absent when zero.
    public var carryCount: Int?
    public var createdAt: Date
    public var updatedAt: Date
    // Schema V2 fields. Every one is optional and absent at its default, so a task that never
    // used them exports exactly as before and an older file imports with the defaults.
    /// Fields the last auto-triage filled (comma-joined), absent when none.
    public var triageFilledFields: String?
    /// Fields set explicitly that triage never overwrites (comma-joined), absent when none.
    public var lockedFields: String?
    /// Review state of an agent's proposal (1 pending, 2 approved, 3 rejected, 4 done by the
    /// agent, awaiting a check), absent when 0.
    public var review: Int?
    public var contextJSON: String?
    public var resultJSON: String?
    public var agentID: UUID?
    /// 1 = assigned to an agent, absent when 0 (the person).
    public var assignee: Int?
    /// Links, files and images, absent when none.
    public var attachments: [ExportedAttachment]?

    public init(id: UUID, title: String, notes: String, firstMove: String?, status: Int,
                priority: Int, depth: Int, effort: Int?, dread: Bool, energyKind: Int?,
                estimateMinutes: Int?, dueDay: String?, originalDueDay: String?,
                completedAt: Date?, sortIndex: Double, ordoIndex: Double?, deletedAt: Date?,
                triagedAt: Date?, triageModel: String?, triageRationale: String?,
                triageFeedback: String?, triageReviewedAt: Date?, needsTriage: Bool,
                recurrenceRule: String?, seriesID: UUID?, calendarEventID: String?,
                externalID: String?, source: String?, projectID: UUID?, labelIDs: [UUID],
                subtasks: [ExportedSubtask], createdAt: Date, updatedAt: Date,
                waitsOn: [UUID]? = nil, parentID: UUID? = nil,
                plannedDay: String? = nil, carryCount: Int? = nil) {
        self.plannedDay = plannedDay
        self.carryCount = carryCount
        self.waitsOn = waitsOn
        self.parentID = parentID
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
        waitsOn = try c.decodeIfPresent([UUID].self, forKey: .waitsOn)
        parentID = try c.decodeIfPresent(UUID.self, forKey: .parentID)
        plannedDay = try c.decodeIfPresent(String.self, forKey: .plannedDay)
        carryCount = try c.decodeIfPresent(Int.self, forKey: .carryCount)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        triageFilledFields = try c.decodeIfPresent(String.self, forKey: .triageFilledFields)
        lockedFields = try c.decodeIfPresent(String.self, forKey: .lockedFields)
        review = try c.decodeIfPresent(Int.self, forKey: .review)
        contextJSON = try c.decodeIfPresent(String.self, forKey: .contextJSON)
        resultJSON = try c.decodeIfPresent(String.self, forKey: .resultJSON)
        agentID = try c.decodeIfPresent(UUID.self, forKey: .agentID)
        assignee = try c.decodeIfPresent(Int.self, forKey: .assignee)
        attachments = try c.decodeIfPresent([ExportedAttachment].self, forKey: .attachments)
    }
}

/// A task's link, file or image (schema V2). File and image bytes travel base64-encoded.
public struct ExportedAttachment: Codable, Equatable {
    public var id: UUID
    public var kind: Int
    public var title: String
    public var url: String?
    public var data: Data?
    public var byteCount: Int
    public var createdAt: Date

    public init(id: UUID, kind: Int, title: String, url: String?, data: Data?,
                byteCount: Int, createdAt: Date) {
        self.id = id; self.kind = kind; self.title = title; self.url = url
        self.data = data; self.byteCount = byteCount; self.createdAt = createdAt
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
        enc.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(ExportDate.string(from: date))
        }
        return enc
    }

    public static func makeDecoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let text = try c.decode(String.self)
            guard let date = ExportDate.date(from: text) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not an ISO 8601 date: \(text)")
            }
            return date
        }
        return dec
    }
}

/// Dates in export and backup files: ISO 8601 UTC with milliseconds (`2026-10-02T09:15:30.123Z`),
/// so a round trip keeps the order of rows created within the same second. Reading accepts both
/// that form and the older whole-second form (`...30Z`), and numeric offsets.
public enum ExportDate {
    /// The fraction is cut off and re-added as integer milliseconds: the stock format styles floor a
    /// value such as `...20.123` (stored as `...20.12299`) to `.122`, which is a 1 ms drift per round trip.
    public static func string(from date: Date) -> String {
        let ms = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let seconds = Int64((Double(ms) / 1000).rounded(.down))
        let millis = ms - seconds * 1000
        let whole = Date(timeIntervalSince1970: Double(seconds)).formatted(Date.ISO8601FormatStyle())
        let fraction = String(format: ".%03d", Int(millis))
        guard whole.hasSuffix("Z") else { return whole + fraction }
        return String(whole.dropLast()) + fraction + "Z"
    }

    public static func date(from text: String) -> Date? {
        var whole = text
        var fraction = 0.0
        if let r = whole.range(of: #"\.\d+"#, options: .regularExpression) {
            fraction = Double("0" + whole[r]) ?? 0
            whole.removeSubrange(r)
        }
        guard let base = parseWhole(whole) else { return nil }
        return base.addingTimeInterval(fraction)
    }

    private static func parseWhole(_ text: String) -> Date? {
        if let d = try? Date.ISO8601FormatStyle().parse(text) { return d }
        // Numeric offsets (+02:00) and any other valid internet date-time the format style rejects.
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)
    }
}
