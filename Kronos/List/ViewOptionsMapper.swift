// Kronos/List/ViewOptionsMapper.swift
// Pure mapping between the DesignSystem's generic sort/filter builder rows (KSortRule,
// KFilterRule, KSortFilterField — which know nothing about KronosCore) and the real
// KSortDescriptor/KFilter the UI persists and Core evaluates. No SwiftUI import, so this
// type is unit-testable on its own per the brief ("put the mapping in a pure, separately
// testable type").
//
// Core rev 4 added `KFilter.Field` + `isNegated(_:)`/`setNegated(_:_:)`: every filterable
// field now has an invertible "is" / "is not" operator (Filtering.swift). Boolean fields
// (Has subtasks, Has notes, Someday, Needs triage, Dread) show `is` / `is not` AS their
// true/false value instead of a second operator control — negating "is true" already
// means "is false" — so `filterFieldNegation(_:)` reports `nil` for them and the popover
// skips the negation toggle there.
import Foundation
import KronosCore

enum ViewOptionsMapper {

    // MARK: - Sort fields

    static let sortFields: [KSortFilterField] = [
        .init(id: KSortKey.manual, name: String(localized: "list.sort.manual"), symbol: "grip-vertical"),
        .init(id: KSortKey.title, name: String(localized: "viewoptions.field.title"), symbol: "pencil"),
        .init(id: KSortKey.status, name: String(localized: "viewoptions.field.status"), symbol: "check"),
        .init(id: KSortKey.priority, name: String(localized: "ctx.task.priority"), symbol: "flag"),
        .init(id: KSortKey.effort, name: String(localized: "viewoptions.field.effort"), symbol: "zap"),
        .init(id: KSortKey.deadline, name: String(localized: "viewoptions.field.deadline"), symbol: "calendar"),
        .init(id: KSortKey.project, name: String(localized: "list.filter.project"), symbol: "folder"),
        .init(id: KSortKey.area, name: String(localized: "viewoptions.field.area"), symbol: "building-2"),
        .init(id: KSortKey.label, name: String(localized: "list.filter.label"), symbol: "bookmark"),
        .init(id: KSortKey.createdAt, name: String(localized: "viewoptions.field.created"), symbol: "clock"),
        .init(id: KSortKey.updatedAt, name: String(localized: "viewoptions.field.updated"), symbol: "clock"),
        .init(id: KSortKey.completedAt, name: String(localized: "viewoptions.field.completed"), symbol: "check-square"),
        .init(id: KSortKey.estimateMinutes, name: String(localized: "detail.estimate"), symbol: "hourglass"),
        .init(id: KSortKey.depth, name: String(localized: "viewoptions.field.depth"), symbol: "target"),
    ]

    /// The field of ANY key, offered or not: a stored key that is no longer offered still draws with its
    /// own name instead of falling back to Manual.
    static func sortField(_ key: KSortKey) -> KSortFilterField {
        sortFields.first { $0.id == AnyHashable(key) } ?? sortFields[0]
    }

    /// The sort fields the editor offers on a list of this shape (never Manual: the default order is
    /// reached with Clear all, not by adding a criterion).
    static func offeredSortFields(for shape: ListShape, showCompleted: Bool) -> [KSortFilterField] {
        ViewFieldCatalog.sortKeys(for: shape, showCompleted: showCompleted).map(sortField)
    }

    private static func sortKey(_ field: KSortFilterField) -> KSortKey {
        (field.id.base as? KSortKey) ?? .manual
    }

    /// `[KSortDescriptor]` -> the builder's `[KSortRule]`, in the same order. The default manual order is
    /// not a rule: it has no row (it could not be removed, it is what remains when every rule is). Each
    /// row's id is its key, so a row keeps its identity across rebuilds.
    static func sortRules(from descriptors: [KSortDescriptor]) -> [KSortRule] {
        descriptors.filter { $0.key != .manual }
            .map { KSortRule(id: AnyHashable($0.key), field: sortField($0.key), ascending: $0.ascending) }
    }

    /// `[KSortRule]` -> `[KSortDescriptor]`, one to one and in order. Whether Manual stays or goes
    /// next to other rows is `ViewOptions.resolveSort`'s call (it needs the previous list).
    static func descriptors(from rules: [KSortRule]) -> [KSortDescriptor] {
        rules.map { KSortDescriptor(key: sortKey($0.field), ascending: $0.ascending) }
    }

    /// `opts` after the sort editor produced `rules`: the one call behind the popover's sort section.
    /// An empty editor means the manual order again; Core decides which rows win (`ViewOptions.replacingSort`).
    static func sortEdit(_ rules: [KSortRule], on opts: ViewOptions) -> ViewOptions {
        opts.replacingSort(with: descriptors(from: rules))
    }

    // MARK: - Filter fields

    enum FilterFieldID: Hashable {
        case status, priority, effort, depth, project, area, label
        case deadline, hasSubtasks, hasNotes, isSomeday, needsTriage, dread, text
    }

    static let filterFields: [KSortFilterField] = [
        .init(id: FilterFieldID.status, name: String(localized: "viewoptions.field.status"), symbol: "check"),
        .init(id: FilterFieldID.priority, name: String(localized: "ctx.task.priority"), symbol: "flag"),
        .init(id: FilterFieldID.effort, name: String(localized: "viewoptions.field.effort"), symbol: "zap"),
        .init(id: FilterFieldID.depth, name: String(localized: "viewoptions.field.depth"), symbol: "target"),
        .init(id: FilterFieldID.project, name: String(localized: "list.filter.project"), symbol: "folder"),
        .init(id: FilterFieldID.area, name: String(localized: "viewoptions.field.area"), symbol: "building-2"),
        .init(id: FilterFieldID.label, name: String(localized: "list.filter.label"), symbol: "bookmark"),
        .init(id: FilterFieldID.deadline, name: String(localized: "viewoptions.field.deadline"), symbol: "calendar"),
        .init(id: FilterFieldID.hasSubtasks, name: String(localized: "viewoptions.field.hassubtasks"), symbol: "list-ordered"),
        .init(id: FilterFieldID.hasNotes, name: String(localized: "detail.notes"), symbol: "message-square"),
        .init(id: FilterFieldID.isSomeday, name: String(localized: "sidebar.someday"), symbol: "archive"),
        .init(id: FilterFieldID.needsTriage, name: String(localized: "viewoptions.field.needstriage"), symbol: "sparkles"),
        .init(id: FilterFieldID.dread, name: String(localized: "detail.dread"), symbol: "heart"),
        .init(id: FilterFieldID.text, name: String(localized: "viewoptions.field.text"), symbol: "search"),
    ]

    static func filterField(_ id: FilterFieldID) -> KSortFilterField {
        filterFields.first { $0.id == AnyHashable(id) } ?? filterFields[0]
    }

    static func filterFieldID(_ field: KSortFilterField) -> FilterFieldID {
        (field.id.base as? FilterFieldID) ?? .status
    }

    /// The editor's field of a Core filter field (total: every Core field has one).
    static func filterFieldID(_ field: KFilter.Field) -> FilterFieldID {
        switch field {
        case .statuses: return .status
        case .priorities: return .priority
        case .efforts: return .effort
        case .depths: return .depth
        case .project: return .project
        case .area: return .area
        case .labels: return .label
        case .due: return .deadline
        case .dread: return .dread
        case .hasNotes: return .hasNotes
        case .hasSubtasks: return .hasSubtasks
        case .isSomeday: return .isSomeday
        case .needsTriage: return .needsTriage
        case .text: return .text
        }
    }

    /// The Core field of an editor field (total, unlike `coreField`, which is nil where the value itself
    /// is the "is / is not" answer).
    static func kFilterField(_ id: FilterFieldID) -> KFilter.Field {
        switch id {
        case .status: return .statuses
        case .priority: return .priorities
        case .effort: return .efforts
        case .depth: return .depths
        case .project: return .project
        case .area: return .area
        case .label: return .labels
        case .deadline: return .due
        case .hasSubtasks: return .hasSubtasks
        case .hasNotes: return .hasNotes
        case .isSomeday: return .isSomeday
        case .needsTriage: return .needsTriage
        case .dread: return .dread
        case .text: return .text
        }
    }

    /// The fields "Add filter" offers on a list of this shape, minus the ones that already have a row.
    static func offeredFilterFields(for shape: ListShape, excluding used: Set<FilterFieldID>) -> [KSortFilterField] {
        ViewFieldCatalog.filterFields(for: shape).map(filterFieldID).filter { !used.contains($0) }.map(filterField)
    }

    // MARK: - Filter edits (pure: what the popover's controls do)

    /// What "Add filter > field" does. The yes/no fields and the deadline start with a value; every other
    /// field starts as a "Choose…" row (`needsValue`) that becomes a real rule when a value is picked.
    static func adding(_ id: FilterFieldID, to filter: KFilter) -> (filter: KFilter, needsValue: Bool) {
        var f = filter
        switch id {
        case .hasSubtasks: f.hasSubtasks = true
        case .hasNotes: f.hasNotes = true
        case .isSomeday: f.isSomeday = true
        case .needsTriage: f.needsTriage = true
        case .dread: f.dread = true
        case .deadline: f.due = .today
        case .status, .priority, .effort, .depth, .project, .area, .label, .text:
            return (f, true)
        }
        return (f, false)
    }

    /// The filter without the constraint of one field (and its inversion).
    static func clearing(_ id: FilterFieldID, from filter: KFilter) -> KFilter {
        var f = filter
        f.clear(kFilterField(id))
        return f
    }

    /// A yes/no field with its value flipped (the row's "is / is not" toggle on those).
    static func togglingBool(_ id: FilterFieldID, in filter: KFilter) -> KFilter {
        var f = filter
        switch id {
        case .hasSubtasks: f.hasSubtasks = f.hasSubtasks.map { !$0 }
        case .hasNotes: f.hasNotes = f.hasNotes.map { !$0 }
        case .isSomeday: f.isSomeday = f.isSomeday.map { !$0 }
        case .needsTriage: f.needsTriage = f.needsTriage.map { !$0 }
        case .dread: f.dread = f.dread.map { !$0 }
        default: break
        }
        return f
    }

    /// One value ticked or unticked in a multi-select menu: the new, sorted selection.
    static func toggling<T: Hashable>(_ value: T, in current: [T], sortedBy order: (T, T) -> Bool) -> [T] {
        var set = Set(current)
        if set.contains(value) { set.remove(value) } else { set.insert(value) }
        return set.sorted(by: order)
    }

    /// The selection of a multi-select field (status, priority, effort, depth) replaced.
    static func setting(_ id: FilterFieldID, ints: [Int], in filter: KFilter) -> KFilter {
        var f = filter
        switch id {
        case .status: f.statuses = ints
        case .priority: f.priorities = ints
        case .effort: f.efforts = ints
        case .depth: f.depths = ints
        default: break
        }
        return f
    }

    /// The Core field this UI field negates, or `nil` for the boolean fields whose
    /// true/false value control already IS the "is"/"is not" choice (spec: "Boolean fields
    /// show is / is not as true/false rather than a second operator").
    static func coreField(_ id: FilterFieldID) -> KFilter.Field? {
        switch id {
        case .status: return .statuses
        case .priority: return .priorities
        case .effort: return .efforts
        case .depth: return .depths
        case .project: return .project
        case .area: return .area
        case .label: return .labels
        case .deadline: return .due
        case .text: return .text
        case .hasSubtasks, .hasNotes, .isSomeday, .needsTriage, .dread: return nil
        }
    }

    // MARK: - Deadline window (KFilter.DueWindow <-> a value summary label + rule storage)

    /// Deadline filter state is stored directly on `KFilter` (due/dueFrom/dueTo); the
    /// builder shows it as one filter row whose value summary this renders.
    static func deadlineSummary(_ f: KFilter) -> String {
        switch f.due {
        case .any: return "Any"
        case .today: return String(localized: "list.filter.due.today")
        case .overdue: return String(localized: "list.filter.due.overdue")
        case .thisWeek, .next7: return String(localized: "list.filter.due.week")
        case .next30: return String(localized: "list.filter.due.next30")
        case .none: return String(localized: "list.filter.due.none")
        case .custom:
            guard let from = f.dueFrom, let to = f.dueTo else { return String(localized: "list.filter.due.custom") }
            return "\(mediumDate(from)) – \(mediumDate(to))"
        }
    }

    private static let mediumFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = KronosLocale.calendar
        f.locale = KronosLocale.current
        f.dateStyle = .medium
        return f
    }()

    /// A day as the APP language's medium date ("15 Sep 2026" / "15. 9. 2026."): never the raw ISO string on screen.
    static func mediumDate(_ day: Int) -> String {
        mediumFormatter.string(from: Day.date(day, calendar: KronosLocale.calendar))
    }

    // MARK: - Filter rules <-> KFilter

    /// Which filter rows a `KFilter` implies, in a stable field order, for rebuilding the
    /// builder's `[KFilterRule]` after a KFilter is loaded (scope switch, saved view open).
    /// `isNegated` on each rule mirrors `f.isNegated(_:)` for that rule's Core field — a
    /// boolean-field rule (`coreField` returns nil for those) never negates, since its
    /// true/false value already answers "is"/"is not".
    static func filterRules(from f: KFilter, compact: Bool = false, pending: [FilterFieldID] = [], projectName: (UUID) -> String?, areaName: (UUID) -> String?, labelName: (UUID) -> String?) -> [KFilterRule] {
        var rules: [KFilterRule] = []
        /// The popover's value column is ~150 pt and its builder hard-truncates with "…", which
        /// left "Waiting,…" unreadable. `compact` (popover only; chips keep the full list) turns a
        /// long list into "first +N": the full selection is one click away in the value menu.
        func joined(_ names: [String]) -> String {
            let all = names.joined(separator: ", ")
            guard compact, names.count > 1, all.count > 14 else { return all }
            return "\(names[0]) +\(names.count - 1)"
        }
        func negated(_ id: FilterFieldID) -> Bool {
            coreField(id).map(f.isNegated) ?? false
        }
        /// A row's id is its field: it keeps its identity (focus, open menu) while its value changes.
        func rule(_ id: FilterFieldID, _ summary: String) -> KFilterRule {
            KFilterRule(id: AnyHashable(id), field: filterField(id), isNegated: negated(id), valueSummary: summary)
        }
        if !f.statuses.isEmpty {
            let names = f.statuses.compactMap { KStatus(rawValue: $0) }.map(statusName)
            rules.append(rule(.status, joined(names)))
        }
        if !f.priorities.isEmpty {
            let names = f.priorities.compactMap { KPriority(rawValue: $0) }.map(priorityName)
            rules.append(rule(.priority, joined(names)))
        }
        if !f.efforts.isEmpty {
            let names = f.efforts.compactMap { KEffort(rawValue: $0) }.map(effortName)
            rules.append(rule(.effort, joined(names)))
        }
        if !f.depths.isEmpty {
            let names = f.depths.compactMap { KDepth(rawValue: $0) }.map(depthName)
            rules.append(rule(.depth, joined(names)))
        }
        if !f.projectIDs.isEmpty || f.noProject {
            var names = f.projectIDs.compactMap(projectName)
            if f.noProject { names.append(String(localized: "viewoptions.noproject")) }
            rules.append(rule(.project, joined(names)))
        }
        if !f.areaIDs.isEmpty {
            let names = f.areaIDs.compactMap(areaName)
            rules.append(rule(.area, joined(names)))
        }
        if !f.labelIDs.isEmpty {
            let names = f.labelIDs.compactMap(labelName)
            rules.append(rule(.label, joined(names)))
        }
        if f.due != .any {
            rules.append(rule(.deadline, deadlineSummary(f)))
        }
        if let v = f.hasSubtasks { rules.append(boolRule(.hasSubtasks, v)) }
        if let v = f.hasNotes { rules.append(boolRule(.hasNotes, v)) }
        if let v = f.isSomeday { rules.append(boolRule(.isSomeday, v)) }
        if let v = f.needsTriage { rules.append(boolRule(.needsTriage, v)) }
        if let v = f.dread { rules.append(boolRule(.dread, v)) }
        if !f.text.isEmpty {
            rules.append(rule(.text, "\"\(f.text)\""))
        }
        // Fields added in the editor that have no value yet: a quiet "Choose…" row each.
        for id in pending where !rules.contains(where: { $0.id == AnyHashable(id) }) {
            var row = rule(id, String(localized: "viewoptions.filter.choose"))
            row.isPlaceholder = true
            rules.append(row)
        }
        return rules
    }

    /// Boolean fields have no negation toggle (spec: "Boolean fields show is / is not as
    /// true/false rather than a second operator") — the value itself is the whole answer.
    private static func boolRule(_ id: FilterFieldID, _ value: Bool) -> KFilterRule {
        KFilterRule(id: AnyHashable(id), field: filterField(id), valueSummary: value ? "true" : "false")
    }

    static func statusName(_ s: KStatus) -> String {
        switch s {
        case .todo: return String(localized: "status.todo")
        case .inProgress: return String(localized: "status.inprogress")
        case .waiting: return String(localized: "status.waiting")
        case .someday: return String(localized: "sidebar.someday")
        case .done: return String(localized: "status.done")
        case .canceled: return String(localized: "status.canceled")
        }
    }
    static func priorityName(_ p: KPriority) -> String {
        switch p {
        case .none: return String(localized: "priority.none")
        case .low: return String(localized: "priority.low")
        case .medium: return String(localized: "priority.medium")
        case .high: return String(localized: "priority.high")
        case .urgent: return String(localized: "priority.urgent")
        }
    }
    static func effortName(_ e: KEffort) -> String {
        switch e {
        case .none: return String(localized: "effort.none")
        case .xs: return String(localized: "effort.xs")
        case .s: return String(localized: "effort.s")
        case .m: return String(localized: "effort.m")
        case .l: return String(localized: "effort.l")
        case .xl: return String(localized: "effort.xl")
        }
    }
    static func depthName(_ d: KDepth) -> String {
        switch d {
        // GAP (reported): no catalog key for KDepth.unknown; shallow/deep both exist.
        case .unknown: return "Unknown"
        case .shallow: return String(localized: "depth.shallow")
        case .deep: return String(localized: "depth.deep")
        }
    }

    // MARK: - Chip labels (KActiveRulesBar)
    // The bar's trailing button now reads "Clear all" (`viewoptions.clearall`). The old key "viewoptions.reset"
    // ("Reset") has no other use; the strings leaf deletes it, because only it may delete catalog keys.

    /// One chip per sort rule, e.g. "Priority ↓".
    static func sortChipText(_ d: KSortDescriptor) -> String {
        "\(sortField(d.key).name) \(d.ascending ? "↑" : "↓")"
    }

    /// One chip per filter rule, e.g. "Effort is S, M" or "Project is not Acme".
    static func filterChipTexts(_ f: KFilter, projectName: (UUID) -> String?, areaName: (UUID) -> String?, labelName: (UUID) -> String?) -> [String] {
        filterRules(from: f, projectName: projectName, areaName: areaName, labelName: labelName).map { rule in
            let op = rule.isNegated ? String(localized: "viewoptions.op.isnot") : String(localized: "viewoptions.op.is")
            return "\(rule.field.name) \(op) \(rule.valueSummary)"
        }
    }

    /// Number of active rules beyond a view's default (empty filter, `[.asc(.manual)]`) —
    /// what the icon button's badge and the chip-bar visibility both key off of.
    static func activeRuleCount(sort: [KSortDescriptor], filter: KFilter) -> Int {
        let sortCount = (sort == KSortDescriptor.default) ? 0 : sort.count
        let filterCount = (filter == .empty) ? 0 : filterRules(from: filter, projectName: { _ in nil }, areaName: { _ in nil }, labelName: { _ in nil }).count
        return sortCount + filterCount
    }
}
