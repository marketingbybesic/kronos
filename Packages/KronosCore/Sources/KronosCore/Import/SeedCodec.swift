import Foundation

// JSON schema v1 — the single codec used by import, export, backup and every
// test fixture. Days are "YYYY-MM-DD" strings;
// instants are ISO-8601 UTC.

public struct SeedFile: Codable {
    public var version: Int
    public var areas: [SeedArea]
    public var projects: [SeedProject]
    public var tags: [SeedTag]?
    public var labels: [SeedLabel]?
    public var rules: [SeedRule]?
    public var savedViews: [SeedSavedView]?
    public var tasks: [SeedTask]

    public init(version: Int = 1,
                areas: [SeedArea] = [],
                projects: [SeedProject] = [],
                tags: [SeedTag] = [],
                labels: [SeedLabel] = [],
                rules: [SeedRule] = [],
                savedViews: [SeedSavedView] = [],
                tasks: [SeedTask] = []) {
        self.version = version
        self.areas = areas
        self.projects = projects
        self.tags = tags
        self.labels = labels
        self.rules = rules
        self.savedViews = savedViews
        self.tasks = tasks
    }
}

public struct SeedArea: Codable {
    public var name: String
    public var colorHex: String
    public var icon: String
    public var sortIndex: Double
    public var id: UUID?
    public var createdAt: Date?
    public var updatedAt: Date?
    public init(name: String, colorHex: String = "#8B8B93", icon: String = "square.grid.2x2",
                sortIndex: Double = 0, id: UUID? = nil,
                createdAt: Date? = nil, updatedAt: Date? = nil) {
        self.name = name; self.colorHex = colorHex; self.icon = icon
        self.sortIndex = sortIndex; self.id = id
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

public struct SeedProject: Codable {
    public var name: String
    public var areaName: String?
    public var colorHex: String
    public var icon: String
    public var sortIndex: Double
    public var isArchived: Bool?
    public var id: UUID?
    public var createdAt: Date?
    public var updatedAt: Date?
    public init(name: String, areaName: String? = nil, colorHex: String = "#8224E3",
                icon: String = "circle", sortIndex: Double = 0, isArchived: Bool? = nil,
                id: UUID? = nil, createdAt: Date? = nil, updatedAt: Date? = nil) {
        self.name = name; self.areaName = areaName; self.colorHex = colorHex
        self.icon = icon; self.sortIndex = sortIndex; self.isArchived = isArchived
        self.id = id; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

public struct SeedTag: Codable {
    public var name: String
    public var colorHex: String?
    public init(name: String, colorHex: String? = nil) {
        self.name = name; self.colorHex = colorHex
    }
}

public struct SeedLabel: Codable {
    public var name: String
    public var colorHex: String?
    public var id: UUID?
    public init(name: String, colorHex: String? = nil, id: UUID? = nil) {
        self.name = name; self.colorHex = colorHex; self.id = id
    }
}

public struct SeedRule: Codable {
    public var text: String
    public var source: String?
    public var scope: Int?
    public var isActive: Bool?
    public init(text: String, source: String? = nil, scope: Int? = nil, isActive: Bool? = nil) {
        self.text = text; self.source = source; self.scope = scope; self.isActive = isActive
    }
}

public struct SeedSavedView: Codable {
    public var name: String
    public var icon: String?
    public var sortIndex: Double?
    public var filter: KFilter?
    public var sortMode: Int?
    public var groupBy: Int?
    public var showDone: Bool?
    public init(name: String, icon: String? = nil, sortIndex: Double? = nil,
                filter: KFilter? = nil, sortMode: Int? = nil, groupBy: Int? = nil,
                showDone: Bool? = nil) {
        self.name = name; self.icon = icon; self.sortIndex = sortIndex
        self.filter = filter; self.sortMode = sortMode; self.groupBy = groupBy
        self.showDone = showDone
    }
}

public struct SeedTask: Codable {
    public var id: UUID?
    public var externalID: String?
    public var source: String?
    public var title: String
    public var notes: String?
    public var firstMove: String?
    public var firstMoveURL: String?
    public var priority: Int?
    public var status: Int?
    public var depth: Int?
    public var dread: Bool?
    public var isSomeday: Bool?
    public var estimateMinutes: Int?
    public var energyKind: Int?
    public var dueDate: String?
    public var originalDueDay: String?
    public var completedAt: Date?
    public var projectName: String?
    public var tags: [String]?
    public var labelIDs: [UUID]?
    public var subtasks: [SeedSubtask]?
    public var createdAt: Date?
    public var updatedAt: Date?
    public var ordoIndex: Double?
    public var sortIndex: Double?
    public var deletedAt: Date?
    public var needsTriage: Bool?
    public var recurrenceRule: String?
    public var seriesID: UUID?

    public init(id: UUID? = nil, externalID: String? = nil, source: String? = nil,
                title: String, notes: String? = nil, firstMove: String? = nil,
                firstMoveURL: String? = nil, priority: Int? = nil, status: Int? = nil,
                depth: Int? = nil, dread: Bool? = nil, isSomeday: Bool? = nil,
                estimateMinutes: Int? = nil, energyKind: Int? = nil,
                dueDate: String? = nil, originalDueDay: String? = nil,
                completedAt: Date? = nil, projectName: String? = nil,
                tags: [String]? = nil, labelIDs: [UUID]? = nil,
                subtasks: [SeedSubtask]? = nil,
                createdAt: Date? = nil, updatedAt: Date? = nil,
                ordoIndex: Double? = nil, sortIndex: Double? = nil,
                deletedAt: Date? = nil, needsTriage: Bool? = nil,
                recurrenceRule: String? = nil, seriesID: UUID? = nil) {
        self.id = id; self.externalID = externalID; self.source = source
        self.title = title; self.notes = notes; self.firstMove = firstMove
        self.firstMoveURL = firstMoveURL; self.priority = priority; self.status = status
        self.depth = depth; self.dread = dread; self.isSomeday = isSomeday
        self.estimateMinutes = estimateMinutes; self.energyKind = energyKind
        self.dueDate = dueDate; self.originalDueDay = originalDueDay
        self.completedAt = completedAt; self.projectName = projectName
        self.tags = tags; self.labelIDs = labelIDs; self.subtasks = subtasks
        self.createdAt = createdAt; self.updatedAt = updatedAt
        self.ordoIndex = ordoIndex; self.sortIndex = sortIndex
        self.deletedAt = deletedAt; self.needsTriage = needsTriage
        self.recurrenceRule = recurrenceRule; self.seriesID = seriesID
    }
}

public struct SeedSubtask: Codable {
    public var title: String
    public var isDone: Bool?
    public var sortIndex: Double?
    public var id: UUID?
    public var createdAt: Date?
    public var updatedAt: Date?
    public init(title: String, isDone: Bool? = nil, sortIndex: Double? = nil,
                id: UUID? = nil, createdAt: Date? = nil, updatedAt: Date? = nil) {
        self.title = title; self.isDone = isDone; self.sortIndex = sortIndex
        self.id = id; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}