// Part of the frozen contract surface. See Contracts.swift.
//
// The list-shaping contract: what a view can be filtered by and how a saved
// view persists its filter and its multi-key ordering. Split out of
// Contracts.swift to keep every contract file under 500 lines.

import Foundation
import SwiftData

// MARK: - KFilter + KSavedView (ux-10)

/// Every field a list can be constrained on. Constraints combine with AND;
/// within one field the members are OR ("any of these priorities").
///
/// An empty collection means "do not constrain on this field" — never "match
/// nothing" — so `KFilter.empty` matches every task.
///
/// rev 3 widened this. Every field added since v1 is optional or defaulted on
/// decode, because `SeedCodec.SeedSavedView` persists a `KFilter` and an older
/// seed file must keep decoding.
public struct KFilter: Codable, Equatable, Sendable {
    public var v: Int = 1
    public var statuses: [Int] = []
    public var priorities: [Int] = []
    public var projectIDs: [UUID] = []
    public var labelIDs: [UUID] = []
    public var due: DueWindow = .any
    public var depths: [Int] = []
    public var dread: Bool? = nil
    public var text: String = ""

    // rev 3 additions
    public var efforts: [Int] = []
    public var areaIDs: [UUID] = []
    /// Matches tasks with no project at all. ORs with `projectIDs`, so
    /// "Inbox or Acme" is expressible.
    public var noProject: Bool = false
    /// Custom deadline range, used only when `due == .custom`. Inclusive.
    public var dueFrom: Int? = nil
    public var dueTo: Int? = nil
    public var hasSubtasks: Bool? = nil
    public var hasNotes: Bool? = nil
    public var isSomeday: Bool? = nil
    public var needsTriage: Bool? = nil

    // MARK: rev 4 — per-field negation
    //
    // Stored as an array of `Field.rawValue` strings rather than a parallel
    // set of `negatedStatuses`-style properties: a new field then needs one
    // enum case, not a second property plus a second decode line, and a v1
    // blob that carries no `negated` key decodes to "nothing negated". A
    // reader that predates rev 4 ignores the extra key entirely, so a filter
    // written by rev 4 still opens in an older build (as a non-negated
    // filter — wider than intended, never narrower, so nothing is hidden
    // from the user by a version mismatch).

    /// The identifiers of the fields whose constraint is inverted.
    /// Prefer `isNegated(_:)` / `setNegated(_:_:)` over touching this array.
    public var negated: [String] = []

    /// Every field a constraint can be placed — and therefore inverted — on.
    /// `matches(_:today:)` switches over this exhaustively, so adding a
    /// filterable field without teaching negation about it will not compile.
    public enum Field: String, Codable, CaseIterable, Sendable {
        case statuses, priorities, efforts, depths
        case project, area, labels
        case due, dread, hasNotes, hasSubtasks, isSomeday, needsTriage, text
    }

    /// True when this field's constraint is inverted ("is none of").
    public func isNegated(_ field: Field) -> Bool {
        negated.contains(field.rawValue)
    }

    /// Invert, or un-invert, one field's constraint. Idempotent.
    public mutating func setNegated(_ field: Field, _ on: Bool) {
        if on {
            guard !isNegated(field) else { return }
            // Kept sorted so two filters built by different code paths encode
            // to identical JSON — G12's byte-identical export depends on it.
            negated = (negated + [field.rawValue]).sorted()
        } else {
            negated.removeAll { $0 == field.rawValue }
        }
    }

    public enum DueWindow: String, Codable, Sendable {
        case any, today, thisWeek, overdue, none
        // rev 3
        case next7, next30, custom

        /// Forward-looking windows, as a day count from today. `thisWeek` is
        /// kept as the v1 spelling of `next7` so an older saved view keeps
        /// behaving identically rather than quietly changing meaning.
        var forwardDays: Int? {
            switch self {
            case .thisWeek, .next7: return 7
            case .next30:           return 30
            default:                return nil
            }
        }
    }

    public static let empty = KFilter()

    public var encodedString: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let d = try? enc.encode(self), let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }

    public static func decode(_ s: String) -> KFilter {
        guard let d = s.data(using: .utf8),
              let f = try? JSONDecoder().decode(KFilter.self, from: d) else { return .empty }
        return f
    }

    public init() {}

    /// Tolerant decode: every key is optional so a v1 blob, or a blob written
    /// by a newer build, still yields a usable filter instead of throwing and
    /// silently falling back to `.empty`.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v           = try c.decodeIfPresent(Int.self, forKey: .v) ?? 1
        statuses    = try c.decodeIfPresent([Int].self, forKey: .statuses) ?? []
        priorities  = try c.decodeIfPresent([Int].self, forKey: .priorities) ?? []
        projectIDs  = try c.decodeIfPresent([UUID].self, forKey: .projectIDs) ?? []
        labelIDs    = try c.decodeIfPresent([UUID].self, forKey: .labelIDs) ?? []
        due         = try c.decodeIfPresent(DueWindow.self, forKey: .due) ?? .any
        depths      = try c.decodeIfPresent([Int].self, forKey: .depths) ?? []
        dread       = try c.decodeIfPresent(Bool.self, forKey: .dread)
        text        = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        efforts     = try c.decodeIfPresent([Int].self, forKey: .efforts) ?? []
        areaIDs     = try c.decodeIfPresent([UUID].self, forKey: .areaIDs) ?? []
        noProject   = try c.decodeIfPresent(Bool.self, forKey: .noProject) ?? false
        dueFrom     = try c.decodeIfPresent(Int.self, forKey: .dueFrom)
        dueTo       = try c.decodeIfPresent(Int.self, forKey: .dueTo)
        hasSubtasks = try c.decodeIfPresent(Bool.self, forKey: .hasSubtasks)
        hasNotes    = try c.decodeIfPresent(Bool.self, forKey: .hasNotes)
        isSomeday   = try c.decodeIfPresent(Bool.self, forKey: .isSomeday)
        needsTriage = try c.decodeIfPresent(Bool.self, forKey: .needsTriage)
        // rev 4. Absent in every v1 blob ⇒ nothing negated, which is exactly
        // how a v1 filter behaved, so an old saved view keeps its meaning.
        negated     = try c.decodeIfPresent([String].self, forKey: .negated) ?? []
    }

    /// True when `task` satisfies every constraint. Pure; `today` is injected
    /// so deadline windows are testable without touching the clock.
    ///
    /// Soft-deleted rows never match: a filter is a view onto live tasks, and
    /// letting a deleted row through here would resurrect it in every list.
    /// Every field's verdict, before negation is applied. `nil` means the
    /// field carries no constraint at all, which is what makes a negated but
    /// empty field INERT: there is nothing to invert, so it neither hides nor
    /// admits anything. (Inverting "no constraint" would otherwise mean
    /// "match nothing", and a user who ticks "not" before choosing a value
    /// would watch their whole list vanish.)
    private func verdict(_ field: Field, _ task: KTask, today: Int) -> Bool? {
        switch field {
        case .statuses:
            return statuses.isEmpty ? nil : statuses.contains(task.statusRaw)
        case .priorities:
            return priorities.isEmpty ? nil : priorities.contains(task.priorityRaw)
        case .efforts:
            return efforts.isEmpty ? nil : efforts.contains(task.effortRaw)
        case .depths:
            return depths.isEmpty ? nil : depths.contains(task.depthRaw)
        case .project:
            // The id set ORs with the explicit "no project" option, so
            // "Inbox or Acme" is expressible — and negating the pair means
            // "in neither", which is the one sensible reading.
            guard !projectIDs.isEmpty || noProject else { return nil }
            let byID = task.projectID.map { projectIDs.contains($0) } ?? false
            let byNone = noProject && task.projectID == nil
            return byID || byNone
        case .area:
            guard !areaIDs.isEmpty else { return nil }
            return task.areaID.map { areaIDs.contains($0) } ?? false
        case .labels:
            guard !labelIDs.isEmpty else { return nil }
            // Multi-value: "any of these" positively, "none of these" negated. A child is never
            // a row of its own, so its parent answers for it (the row marks the child).
            return task.selfOrChildCarriesAnyLabel(of: Set(labelIDs))
        case .due:
            return due == .any ? nil : matchesDue(task, today: today)
        case .dread:
            return dread.map { task.dread == $0 }
        case .hasNotes:
            return hasNotes.map { !task.notes.isEmpty == $0 }
        case .hasSubtasks:
            return hasSubtasks.map { !task.orderedChildren.isEmpty == $0 }
        case .isSomeday:
            return isSomeday.map { (task.status == .someday) == $0 }
        case .needsTriage:
            return needsTriage.map { task.needsTriage == $0 }
        case .text:
            guard !text.isEmpty else { return nil }
            let needle = KTextFold.fold(text)
            let hay = KTextFold.fold(task.title) + " " + KTextFold.fold(task.notes)
            return hay.contains(needle) || task.titleOrSubtaskTitleContains(needle)
        }
    }

    /// True when `task` satisfies every constraint. Pure; `today` is injected
    /// so deadline windows are testable without touching the clock.
    ///
    /// Soft-deleted rows never match: a filter is a view onto live tasks, and
    /// letting a deleted row through here would resurrect it in every list.
    ///
    /// rev 4: each field is evaluated, then inverted when that field is
    /// negated, then AND-combined with every other field exactly as before —
    /// negation is per field, never a blanket "NOT (whole filter)".
    public func matches(_ task: KTask, today: Int) -> Bool {
        // A proposal an agent made and nobody has decided yet (reviewRaw 1) belongs to no list, view or search.
        guard task.deletedAt == nil, task.reviewRaw != 1 else { return false }
        for field in Field.allCases {
            guard let hit = verdict(field, task, today: today) else { continue }
            if hit == isNegated(field) { return false }
        }
        return true
    }

    private func matchesDue(_ task: KTask, today: Int) -> Bool {
        if due == .any { return true }
        if due == .none { return task.effectiveDue == nil }

        // The forward windows (today, next 7 days, this week, next 30 days) read the schedule
        // day: the planned day when there is one, else the effective due day. The deadline
        // windows (overdue, custom) always read the deadline itself.
        switch due {
        case .today:
            return DueScope.isScheduledByToday(task, today: today)   // scheduled today or already carried
        case .thisWeek, .next7, .next30:
            guard let span = due.forwardDays else { return true }
            return DueScope.isScheduled(task, from: today, through: today + span)
        default:
            break
        }

        // Every remaining window requires a deadline, so an undated task can
        // never match one — including `.custom` with both bounds left open.
        guard let d = task.effectiveDue else { return false }

        switch due {
        case .overdue:
            return d < today
        case .custom:
            if let f = dueFrom, d < f { return false }
            if let t = dueTo,   d > t { return false }
            return true
        default:
            return true
        }
    }
}

@Model
public final class KSavedView {
    public var id: UUID = UUID()
    public var name: String = ""
    public var icon: String = "line.3.horizontal.decrease.circle"
    public var sortIndex: Double = 0
    public var filterJSON: String = "{}"
    public var sortModeRaw: Int = KSortMode.priorityThenDue.rawValue
    public var groupByRaw: Int = KGroupBy.none.rawValue
    /// rev 3: the multi-key ordering, as a Codable blob. Stored alongside the
    /// legacy `sortModeRaw` rather than replacing it, so a view written by an
    /// older build still opens; `sortDescriptors` is what rev 3 UI reads.
    public var sortJSON: String = "[]"
    public var showDone: Bool = false
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    public init(name: String,
                filter: KFilter,
                sortMode: KSortMode = .priorityThenDue,
                groupBy: KGroupBy = .none,
                showDone: Bool = false,
                sortIndex: Double = 0,
                sort: [KSortDescriptor] = []) {
        self.name        = name
        self.filterJSON  = filter.encodedString
        self.sortModeRaw = sortMode.rawValue
        self.groupByRaw  = groupBy.rawValue
        self.showDone    = showDone
        self.sortIndex   = sortIndex
        self.sortJSON    = KSavedView.encodeSort(sort)
    }

    static func encodeSort(_ sort: [KSortDescriptor]) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let d = try? enc.encode(sort), let s = String(data: d, encoding: .utf8) else { return "[]" }
        return s
    }
}

extension KSavedView {
    public var sortMode: KSortMode {
        get { KSortMode(rawValue: sortModeRaw) ?? .priorityThenDue }
        set { sortModeRaw = newValue.rawValue }
    }
    public var groupBy: KGroupBy {
        get { KGroupBy(rawValue: groupByRaw) ?? .none }
        set { groupByRaw = newValue.rawValue }
    }
    public var filter: KFilter { KFilter.decode(filterJSON) }

    /// The rev 3 multi-key ordering. Falls back to the legacy `sortMode` when
    /// the view predates rev 3, so an old saved view still sorts sensibly
    /// instead of collapsing to manual order.
    public var sortDescriptors: [KSortDescriptor] {
        get {
            if let d = sortJSON.data(using: .utf8),
               let s = try? JSONDecoder().decode([KSortDescriptor].self, from: d),
               !s.isEmpty {
                return s
            }
            switch sortMode {
            case .manual:          return [.asc(.manual)]
            case .priorityThenDue: return [.asc(.deadline), .desc(.priority)]
            }
        }
        set { sortJSON = KSavedView.encodeSort(newValue) }
    }
}

// MARK: - Views that belong to one project
//
// A saved view made inside a project is a filter that pins exactly that project. Nothing is stored
// besides the filter (no column on `KSavedView`, no schema change): "belongs to project P" is read off
// the filter, so export, import, seed and sync carry it unchanged.

extension KFilter {
    /// This filter narrowed to exactly one project: any other project choice, "no project" and the
    /// inversion of the project field are replaced. Every other field is kept.
    public func pinned(to projectID: UUID) -> KFilter {
        var f = self
        f.projectIDs = [projectID]
        f.noProject = false
        f.setNegated(.project, false)
        return f
    }

    /// The one project this filter is pinned to, or nil when it names none, several, "no project" or
    /// the inverse of a project.
    public var pinnedProjectID: UUID? {
        guard projectIDs.count == 1, !noProject, !isNegated(.project) else { return nil }
        return projectIDs[0]
    }
}

extension KSavedView {
    /// The project this view belongs to (shown under it in the sidebar), read off its filter.
    public var homeProjectID: UUID? { filter.pinnedProjectID }

    /// How many of `tasks` the view lists, open ones only unless the view itself asks for a status:
    /// the number beside it in the sidebar.
    public func memberCount(in tasks: [KTask], today: Int) -> Int {
        let f = filter
        return tasks.filter { f.matches($0, today: today) && (!f.statuses.isEmpty || KStatus.open.contains($0.status)) }.count
    }
}

extension ViewOptions {
    /// These options with the filter pinned to `projectID`.
    public func pinned(to projectID: UUID) -> ViewOptions {
        var copy = self
        copy.filter = filter.pinned(to: projectID)
        return copy
    }

    /// Clear all for a list that belongs to a project: every sort and filter goes except the pin.
    /// With no pin it is exactly `cleared()`.
    public func cleared(keepingPin pin: UUID?) -> ViewOptions {
        let base = cleared()
        return pin.map(base.pinned(to:)) ?? base
    }

    /// True when Clear all would change something: a sort, or a filter beyond the pin.
    public func hasRulesToClear(keepingPin pin: UUID?) -> Bool {
        self != cleared(keepingPin: pin)
    }
}
