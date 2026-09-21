// KronosCore frozen contract surface.
// Naming law (macos-1): no public KronosCore type may reuse a name exported by
// Swift stdlib, Foundation, SwiftUI or AppKit. All model types carry a K prefix.
//
// The surface is split across this file and Contracts/ so no file exceeds 500
// lines. Every consumer leaf compiles against these and nothing else:
//
//   Contracts.swift            enums, Day, and the @Model classes (this file)
//   Runtime.swift              Ordering, schema version, KronosStore,
//                              KronosTiming, OrdoFocus, notification names
//   Filtering.swift            KFilter (+ matches) and KSavedView
//   Contracts/TaskStoring.swift  the complete mutation surface, incl. the
//                              …NoUndo variants reserved for MCP and triage
//   Contracts/AI.swift         AIClient, AIRequest, AIResponse, AIError,
//                              AIRouting, DataPolicy, AIMode, AIBudget
//   Contracts/AIDTOs.swift     TriageResult, ImpulsRanking, OrdoResort,
//                              ProposedRule
//   Contracts/Ranking.swift    RankingProviding (Candidate ships beside the
//                              concrete RankingEngine)
//   Contracts/MCPTool.swift    the 13 alpha tools and their JSON schemas
//   Contracts/MCPParams.swift  the tools' Codable params structs
//   Contracts/Sorting.swift    KSortKey, KSortDescriptor, KTaskSorter, KTextFold
//
// Everything under Contracts/ (TaskStoring's full mutation surface, AI types, DTOs) evolves
// additively: earlier declarations are never renamed or removed, only extended — a consumer
// leaf that compiled against an earlier version keeps compiling. `sortMode`/`groupBy` still
// exist beside the newer `sortDescriptors` for exactly this reason. `ordoIndex`, `OrdoEngine`
// and the ordo store methods are LEFT IN PLACE but not expanded: ORDO is now derived from the
// open list, not hand-curated.
//
// Deliberately NOT here: DesignToken. Design tokens are owned by the app
// target so that Core carries no opinion about how a row looks.
//
// `KProject.icon` is `String?`, defaulted `nil` — a project's icon is picked from a curated
// Icon-map name (the same Lucide catalogue §7.3 names `Project.icon` as); `nil` means "no icon
// chosen — render the plain colour dot" rather than forcing every project onto a fallback
// glyph. `emoji` is retired from the UI (§12.8) but the field and export both keep it, so
// nothing already set is lost.

import Foundation
import SwiftData

// MARK: - Enums

public enum KStatus: Int, Codable, CaseIterable, Sendable {
    case todo       = 0
    case inProgress = 1
    case waiting    = 2
    case someday    = 3
    case done       = 4
    case canceled   = 5

    public static let active: Set<KStatus> = [.todo, .inProgress]
    public static let open:   Set<KStatus> = [.todo, .inProgress, .waiting, .someday]
    public static let closed: Set<KStatus> = [.done, .canceled]

    public static let activeRaw: [Int] = [0, 1]
    public static let openRaw:   [Int] = [0, 1, 2, 3]
    public static let closedRaw: [Int] = [4, 5]
    public static let allRaw:    [Int] = [0, 1, 2, 3, 4, 5]
}

public enum KPriority: Int, Codable, CaseIterable, Sendable {
    case none = 0, low = 1, medium = 2, high = 3, urgent = 4
}

/// How much work the task is, as the user judges it.
///
/// One of the three first-class user attributes — effort, deadline
/// (`dueDay`), priority. Distinct from `depth` and `estimateMinutes`, which
/// stay exactly as they were because the ADHD engine ranks on them: `depth`
/// is attention demand and `estimateMinutes` is a predicted duration, while
/// effort is the user's own coarse sizing and drives no ranking.
public enum KEffort: Int, Codable, CaseIterable, Sendable {
    case none = 0
    case xs   = 1
    case s    = 2
    case m    = 3
    case l    = 4
    case xl   = 5
}

/// adhd-4: Depth is ATTENTION DEMAND ONLY. Never emotional weight.
public enum KDepth: Int, Codable, CaseIterable, Sendable {
    case unknown = 0
    case shallow = 1
    case deep    = 2
}

public enum KEnergyKind: Int, Codable, CaseIterable, Sendable {
    case deepWork = 0, admin = 1, creative = 2, people = 3, physical = 4
}

public enum KEnergyLevel: Int, Codable, CaseIterable, Sendable {
    case low = 0, mid = 1, high = 2
}

public enum KRuleScope: Int, Codable, CaseIterable, Sendable {
    case all = 0, triage = 1, impuls = 2, ordo = 3
}

public enum KRuleSource: Int, Codable, CaseIterable, Sendable {
    case feedback = 0, manual = 1, ordoProposal = 2
}

public enum KSortMode: Int, Codable, CaseIterable, Sendable {
    case manual = 0
    case priorityThenDue = 1
}

public enum KGroupBy: Int, Codable, CaseIterable, Sendable {
    case none = 0, status = 1, project = 2, priority = 3
}

// MARK: - Day (data-6)

public enum Day {
    /// Days since 1970-01-01 in the current calendar/timezone.
    public static func from(_ date: Date, calendar: Calendar = .current) -> Int {
        let start = calendar.startOfDay(for: date)
        let epoch = calendar.startOfDay(for: Date(timeIntervalSince1970: 0))
        return calendar.dateComponents([.day], from: epoch, to: start).day ?? 0
    }

    /// Local midnight of the given day number.
    public static func date(_ day: Int, calendar: Calendar = .current) -> Date {
        let epoch = calendar.startOfDay(for: Date(timeIntervalSince1970: 0))
        return calendar.date(byAdding: .day, value: day, to: epoch)!
    }

    public static func today(calendar: Calendar = .current) -> Int {
        from(Date(), calendar: calendar)
    }

    /// Wire format "YYYY-MM-DD" (local calendar day, no timezone).
    public static func iso(_ day: Int) -> String { isoFormatter.string(from: date(day)) }
    public static func parseISO(_ s: String) -> Int? { isoFormatter.date(from: s).map { from($0) } }

    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar   = Calendar(identifier: .gregorian)
        f.locale     = Locale(identifier: "en_US_POSIX")
        f.timeZone   = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

// MARK: - KArea

@Model
public final class KArea {
    public var id: UUID = UUID()
    public var name: String = ""
    public var colorHex: String = "#8B8B93"
    public var icon: String = "square.grid.2x2"
    public var sortIndex: Double = 0
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    @Relationship(deleteRule: .nullify, inverse: \KProject.area)
    public var projects: [KProject]? = []

    public init(name: String,
                colorHex: String = "#8B8B93",
                icon: String = "square.grid.2x2",
                sortIndex: Double = 0) {
        self.name = name
        self.colorHex = colorHex
        self.icon = icon
        self.sortIndex = sortIndex
    }

    /// Ordered by the full manual tie-break chain (sortIndex, createdAt, id).
    public var orderedProjects: [KProject] {
        (projects ?? []).sorted {
            if $0.sortIndex != $1.sortIndex { return $0.sortIndex < $1.sortIndex }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}

// MARK: - KProject

@Model
public final class KProject {
    public var id: UUID = UUID()
    public var name: String = ""
    public var colorHex: String = "#8224E3"
    /// A curated Icon-map name (Lucide asset, spec §7.3), or nil for the
    /// plain colour dot. Optional rather than defaulting to a fallback icon
    /// string: identity now reads color + icon (§12.8), and a project not
    /// yet customised should fall back to a dot, not a generic circle glyph
    /// indistinguishable from a real choice.
    public var icon: String? = nil
    /// A user-chosen emoji. Retired from the UI as of §12.8 — icon +
    /// colour is now the on-screen identity — but the field and export both
    /// keep it, so nothing already set is lost.
    public var emoji: String? = nil
    public var sortIndex: Double = 0
    public var isArchived: Bool = false
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    public var area: KArea?

    @Relationship(deleteRule: .nullify, inverse: \KTask.project)
    public var tasks: [KTask]? = []

    public init(name: String,
                colorHex: String = "#8224E3",
                icon: String? = nil,
                area: KArea? = nil,
                sortIndex: Double = 0,
                emoji: String? = nil) {
        self.name = name
        self.colorHex = colorHex
        self.icon = icon
        self.area = area
        self.sortIndex = sortIndex
        self.emoji = emoji
    }
}

// MARK: - KLabel

@Model
public final class KLabel {
    public var id: UUID = UUID()
    public var name: String = ""
    public var colorHex: String = "#8B8B93"
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    public var tasks: [KTask]? = []    // inverse declared on KTask.labels

    public init(name: String, colorHex: String = "#8B8B93") {
        self.name = name
        self.colorHex = colorHex
    }

    /// Case- and diacritic-insensitive merge key. đ does not fold: mapped
    /// explicitly BEFORE folding, folding locale pinned to en_US_POSIX.
    public var mergeKey: String {
        let mapped = name.replacingOccurrences(of: "đ", with: "d")
                          .replacingOccurrences(of: "Đ", with: "D")
        return mapped.folding(options: [.caseInsensitive, .diacriticInsensitive],
                              locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - KTask

@Model
public final class KTask {
    // identity & timestamps
    public var id: UUID = UUID()
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    // content
    public var title: String = ""
    public var notes: String = ""
    public var firstMove: String? = nil

    // classification (raw Ints so #Predicate can compare them)
    public var statusRaw: Int = KStatus.todo.rawValue
    public var priorityRaw: Int = KPriority.none.rawValue
    public var depthRaw: Int = KDepth.unknown.rawValue
    public var effortRaw: Int = KEffort.none.rawValue
    public var dread: Bool = false
    public var energyKindRaw: Int? = nil
    public var estimateMinutes: Int? = nil

    // scheduling (data-6: day granularity, never an instant)
    public var dueDay: Int? = nil
    public var originalDueDay: Int? = nil
    public var completedAt: Date? = nil

    // ordering
    public var sortIndex: Double = 0
    public var ordoIndex: Double? = nil

    // soft delete (scope-4): non-nil = deleted, excluded by livePredicate
    public var deletedAt: Date? = nil

    // triage (data-8: TriageInfo inlined)
    public var triagedAt: Date? = nil
    public var triageModel: String? = nil
    public var triageRationale: String? = nil
    public var triageFeedback: String? = nil
    public var triageReviewedAt: Date? = nil
    public var needsTriage: Bool = true

    // recurrence (data-7)
    public var recurrenceRule: String? = nil
    public var seriesID: UUID? = nil

    // calendar (D20)
    public var calendarEventID: String? = nil

    // external origin (L1b import; no @Attribute(.unique) under CloudKit)
    public var externalID: String? = nil
    public var source: String? = nil

    // scalar mirrors — #Predicate cannot traverse optional to-one/to-many
    public var projectID: UUID? = nil
    public var areaID: UUID? = nil
    public var isProjectArchived: Bool = false

    // relationships
    public var project: KProject?

    @Relationship(deleteRule: .nullify, inverse: \KLabel.tasks)
    public var labels: [KLabel]? = []

    @Relationship(deleteRule: .cascade, inverse: \KSubtask.task)
    public var subtasks: [KSubtask]? = []

    public init(title: String, notes: String = "", project: KProject? = nil) {
        self.title             = title
        self.notes             = notes
        self.project           = project
        self.projectID         = project?.id
        self.areaID            = project?.area?.id
        self.isProjectArchived = project?.isArchived ?? false
    }
}

extension KTask {
    public var status: KStatus {
        get { KStatus(rawValue: statusRaw) ?? .todo }
        set { statusRaw = newValue.rawValue }
    }
    public var priority: KPriority {
        get { KPriority(rawValue: priorityRaw) ?? .none }
        set { priorityRaw = newValue.rawValue }
    }
    public var depth: KDepth {
        get { KDepth(rawValue: depthRaw) ?? .unknown }
        set { depthRaw = newValue.rawValue }
    }
    public var effort: KEffort {
        get { KEffort(rawValue: effortRaw) ?? .none }
        set { effortRaw = newValue.rawValue }
    }
    public var energyKind: KEnergyKind? {
        get { energyKindRaw.flatMap(KEnergyKind.init(rawValue:)) }
        set { energyKindRaw = newValue?.rawValue }
    }

    /// Computed at render. NEVER stored, NEVER written by a job.
    public func carryDays(today: Int) -> Int {
        guard let d = dueDay, KStatus.open.contains(status) else { return 0 }
        return max(0, today - d)
    }

    /// data-14: to-many relationships carry no order.
    public var orderedSubtasks: [KSubtask] {
        (subtasks ?? []).sorted {
            if $0.sortIndex != $1.sortIndex { return $0.sortIndex < $1.sortIndex }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
    public var nextOpenSubtask: KSubtask? { orderedSubtasks.first { !$0.isDone } }
    public var subtaskProgress: (done: Int, total: Int) {
        let all = subtasks ?? []
        return (all.filter(\.isDone).count, all.count)
    }

    public var isInOrdo: Bool { ordoIndex != nil }
    public var isTriagedUnreviewed: Bool { triagedAt != nil && triageReviewedAt == nil }
}

// MARK: - KSubtask

@Model
public final class KSubtask {
    public var id: UUID = UUID()
    public var title: String = ""
    public var isDone: Bool = false
    public var sortIndex: Double = 0
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    public var task: KTask?

    public init(title: String, sortIndex: Double = 0) {
        self.title = title
        self.sortIndex = sortIndex
    }
}

// MARK: - KRule

@Model
public final class KRule {
    public var id: UUID = UUID()
    public var text: String = ""
    public var scopeRaw: Int = KRuleScope.all.rawValue
    public var sourceRaw: Int = KRuleSource.manual.rawValue
    public var isActive: Bool = true
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    public init(text: String, scope: KRuleScope = .all, source: KRuleSource = .manual) {
        self.text      = String(text.prefix(160))
        self.scopeRaw  = scope.rawValue
        self.sourceRaw = source.rawValue
    }
}

extension KRule {
    public var scope: KRuleScope {
        get { KRuleScope(rawValue: scopeRaw) ?? .all }
        set { scopeRaw = newValue.rawValue }
    }
    public var source: KRuleSource {
        get { KRuleSource(rawValue: sourceRaw) ?? .manual }
        set { sourceRaw = newValue.rawValue }
    }
}

