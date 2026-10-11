// Kronos/List/ListGrouping.swift
// Pure partitioning of a list's rows into the sticky sections "Group by" shows (spec §4.5-4.6):
// which group each task belongs to, the groups' fixed display order per mode, and which groups
// to render (an empty one is skipped — there is no "show empty groups" toggle yet). No view
// code, no store access: everything here reads straight off the KTask relationships already
// loaded on each row, so it works identically whether `rows` came from a live fetch or a
// fixture in a test.
import Foundation
import KronosCore

enum ListGrouping {

    /// What a section header's leading mark should show, if anything. Kept data-only (no
    /// `Color`) so this file never needs SwiftUI; ListGroupedSections.swift resolves it to a
    /// real colour (project hue respects the user's accent/monochrome mode; priority reuses
    /// `PriorityGlyph`'s own tones).
    enum GroupLeading: Equatable {
        case none
        /// A project's own colour, as stored on `KProject.colorHex`.
        case projectColor(String)
        /// A fixed priority level 0 (none) ... 4 (urgent), matching `KPriority.rawValue`.
        case priorityLevel(Int)
    }

    /// One rendered section: a stable key (anchors + collapse state), the already-localized
    /// header title, its rows in list order, and what the header's leading mark shows.
    struct Section: Identifiable {
        let key: String
        let title: String
        let rows: [KTask]
        let leading: GroupLeading
        var id: String { key }
    }

    /// `rows` split into `mode`'s sections, in the fixed order spec §4.6 gives each mode, each
    /// group's own rows kept in the order they arrived in (i.e. whatever the list's own sort
    /// already produced — grouping only partitions, it never reorders within a group). `.none`
    /// returns every row as one untitled section: TaskListScreen never actually renders that
    /// (it falls back to the flat list for `.none`), this just keeps the function total.
    static func sections(_ rows: [KTask], mode: KGroupBy) -> [Section] {
        switch mode {
        case .none: return [Section(key: "none", title: "", rows: rows, leading: .none)]
        case .status: return statusSections(rows)
        case .priority: return prioritySections(rows)
        case .project: return projectSections(rows)
        case .due: return dueSections(rows)
        }
    }

    /// The group `task` belongs to under `mode`; nil for `.none` (nothing is grouped). Two
    /// tasks with an equal key are in the same group — shared by `sections(_:mode:)` above and
    /// the drag engine's cross-group drop guard below, so both always agree.
    static func groupKey(of task: KTask, mode: KGroupBy) -> String? {
        switch mode {
        case .none: return nil
        case .status: return "status.\(task.statusRaw)"
        case .priority: return "priority.\(task.priorityRaw)"
        case .project: return task.projectID.map { "project.\($0.uuidString)" } ?? "project.none"
        case .due: return "due.\(dueBucket(task).rawValue)"
        }
    }

    /// `rows`, re-ordered to match what "Group by" actually draws on screen: each section in
    /// its fixed order, a collapsed group's rows skipped entirely — not just visually hidden but
    /// absent from the walk, so arrow-key navigation and the post-complete/delete neighbour
    /// (TaskListScreen+Keys.swift, ListCompletion.swift) only ever land on a row that is really
    /// visible. `.none` is an identity fast-path: nothing to reorder when the list is not
    /// grouped, and no `sections` cost on every keystroke of a list that never groups.
    static func displayOrder(rows: [KTask], mode: KGroupBy, collapsed: (String) -> Bool) -> [KTask] {
        guard mode != .none else { return rows }
        return displayOrder(sections: sections(rows, mode: mode), collapsed: collapsed)
    }

    /// Same as above, from a `sections(_:mode:)` result the caller already has — what
    /// `ListContext` uses (Kronos/List/ListContext.swift): it partitions once per build for the
    /// grouped renderer (ListGroupedSections.swift) and must not partition a second time here
    /// just to get the walking order, or renderer and navigation could drift apart over time.
    static func displayOrder(sections: [Section], collapsed: (String) -> Bool) -> [KTask] {
        sections.flatMap { collapsed($0.key) ? [] : $0.rows }
    }

    /// True when dropping `dragged` at `target`'s position would move it into a different
    /// group than it is in now. Spec §4.5: manual order applies WITHIN a group once grouping is
    /// on; a reorder that would cross a group boundary has no sensible meaning (it is not a
    /// status/priority/project/due change, so it is rejected rather than silently reinterpreted).
    static func crossesGroup(dragging dragged: KTask, onto target: KTask, mode: KGroupBy) -> Bool {
        guard mode != .none else { return false }
        return groupKey(of: dragged, mode: mode) != groupKey(of: target, mode: mode)
    }

    // MARK: - Status (spec §4.6: In progress · Todo · Waiting · Done · Canceled)

    // `.someday` is not in the spec table — an ordinary list never mixes Someday-status tasks
    // with the rest (ListStatusPolicy: Someday is its own single-status scope) — but a task
    // explicitly filtered into view with that status must still get a group rather than
    // silently vanish, so it sits right after Waiting, its own position in KStatus's raw order.
    private static let statusOrder: [KStatus] = [.inProgress, .todo, .waiting, .someday, .done, .canceled]

    private static func statusSections(_ rows: [KTask]) -> [Section] {
        let byStatus = Dictionary(grouping: rows) { $0.status }
        return statusOrder.compactMap { status in
            guard let group = byStatus[status], !group.isEmpty else { return nil }
            return Section(key: "status.\(status.rawValue)", title: ViewOptionsMapper.statusName(status),
                           rows: group, leading: .none)
        }
    }

    // MARK: - Priority (spec §4.6: Urgent · High · Medium · Low · No priority)

    private static let priorityOrder: [KPriority] = [.urgent, .high, .medium, .low, .none]

    private static func prioritySections(_ rows: [KTask]) -> [Section] {
        let byPriority = Dictionary(grouping: rows) { $0.priority }
        return priorityOrder.compactMap { priority in
            guard let group = byPriority[priority], !group.isEmpty else { return nil }
            return Section(key: "priority.\(priority.rawValue)", title: ViewOptionsMapper.priorityName(priority),
                           rows: group, leading: .priorityLevel(priority.rawValue))
        }
    }

    // MARK: - Project (spec §4.6: `sortIndex` of area, then of project; "No project" last)

    private static func projectSections(_ rows: [KTask]) -> [Section] {
        var byProject: [UUID: [KTask]] = [:]
        var projectsByID: [UUID: KProject] = [:]
        var noProject: [KTask] = []
        for task in rows {
            if let project = task.project {
                byProject[project.id, default: []].append(task)
                projectsByID[project.id] = project
            } else {
                noProject.append(task)
            }
        }
        let ordered = projectsByID.values.sorted(by: projectGroupOrder)
        var sections = ordered.map { project in
            Section(key: "project.\(project.id.uuidString)", title: project.name,
                   rows: byProject[project.id] ?? [], leading: .projectColor(project.colorHex))
        }
        if !noProject.isEmpty {
            sections.append(Section(key: "project.none", title: String(localized: "viewoptions.noproject"),
                                    rows: noProject, leading: .none))
        }
        return sections
    }

    /// Total order: the project's area's own (sortIndex, createdAt, id) chain first — so two
    /// projects in different areas never tie-break on project `sortIndex`, which is meaningless
    /// across areas — then the project's own (sortIndex, createdAt, id), same chain
    /// `KArea.orderedProjects` (Contracts.swift) already uses for the sidebar.
    private static func projectGroupOrder(_ a: KProject, _ b: KProject) -> Bool {
        let areaA = areaRank(a), areaB = areaRank(b)
        if areaA != areaB { return areaA < areaB }
        if a.sortIndex != b.sortIndex { return a.sortIndex < b.sortIndex }
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.id.uuidString < b.id.uuidString
    }

    private static func areaRank(_ project: KProject) -> AreaRank {
        guard let area = project.area else { return AreaRank(sortIndex: .greatestFiniteMagnitude, createdAt: .distantFuture, id: "") }
        return AreaRank(sortIndex: area.sortIndex, createdAt: area.createdAt, id: area.id.uuidString)
    }

    private struct AreaRank: Equatable, Comparable {
        let sortIndex: Double
        let createdAt: Date
        let id: String
        static func < (lhs: AreaRank, rhs: AreaRank) -> Bool {
            if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id < rhs.id
        }
    }

    // MARK: - Due (spec §4.6: Overdue · Today · Tomorrow · This week · Later · No due date)

    /// "This week" matches the existing Due-filter window (`KFilter.DueWindow.next7`, the same
    /// rolling 7-day-from-today span the "This week" filter chip already uses), minus the two
    /// days that get their own buckets (today, tomorrow) — not a calendar-week boundary, which
    /// nothing else in this app computes.
    enum DueBucket: String {
        case overdue, today, tomorrow, thisWeek, later, none
    }

    static func dueBucket(_ task: KTask) -> DueBucket {
        guard let due = task.effectiveDue else { return .none }
        let today = Day.today()
        if due < today { return .overdue }
        if due == today { return .today }
        if due == today + 1 { return .tomorrow }
        if due <= today + 7 { return .thisWeek }
        return .later
    }

    private static let dueOrder: [DueBucket] = [.overdue, .today, .tomorrow, .thisWeek, .later, .none]

    private static func dueTitle(_ bucket: DueBucket) -> String {
        switch bucket {
        case .overdue: return String(localized: "list.groupby.due.overdue")
        case .today: return String(localized: "list.filter.due.today")
        case .tomorrow: return String(localized: "deadline.quick.tomorrow")
        case .thisWeek: return String(localized: "list.filter.due.week")
        case .later: return String(localized: "list.groupby.due.later")
        case .none: return String(localized: "list.groupby.due.none")
        }
    }

    private static func dueSections(_ rows: [KTask]) -> [Section] {
        let byBucket = Dictionary(grouping: rows, by: dueBucket)
        return dueOrder.compactMap { bucket in
            guard let group = byBucket[bucket], !group.isEmpty else { return nil }
            return Section(key: "due.\(bucket.rawValue)", title: dueTitle(bucket), rows: group, leading: .none)
        }
    }
}
