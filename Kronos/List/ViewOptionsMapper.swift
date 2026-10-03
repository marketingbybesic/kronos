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

    static func sortField(_ key: KSortKey) -> KSortFilterField {
        sortFields.first { $0.id == AnyHashable(key) } ?? sortFields[0]
    }

    private static func sortKey(_ field: KSortFilterField) -> KSortKey {
        (field.id.base as? KSortKey) ?? .manual
    }

    /// `[KSortDescriptor]` -> the builder's `[KSortRule]`, in the same order.
    static func sortRules(from descriptors: [KSortDescriptor]) -> [KSortRule] {
        descriptors.map { KSortRule(field: sortField($0.key), ascending: $0.ascending) }
    }

    /// `[KSortRule]` -> `[KSortDescriptor]`, one to one and in order. Whether Manual stays or goes
    /// next to other rows is `ViewOptions.resolveSort`'s call (it needs the previous list).
    static func descriptors(from rules: [KSortRule]) -> [KSortDescriptor] {
        rules.map { KSortDescriptor(key: sortKey($0.field), ascending: $0.ascending) }
    }

    /// `opts` after the sort editor produced `rules`: the one call behind the popover's sort section.
    /// The editor lists a manual order as a row, so an added criterion arrives next to it; Core decides
    /// which one wins (`ViewOptions.replacingSort`).
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
    static func filterRules(from f: KFilter, compact: Bool = false, projectName: (UUID) -> String?, areaName: (UUID) -> String?, labelName: (UUID) -> String?) -> [KFilterRule] {
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
        if !f.statuses.isEmpty {
            let names = f.statuses.compactMap { KStatus(rawValue: $0) }.map(statusName)
            rules.append(KFilterRule(field: filterField(.status), isNegated: negated(.status), valueSummary: joined(names)))
        }
        if !f.priorities.isEmpty {
            let names = f.priorities.compactMap { KPriority(rawValue: $0) }.map(priorityName)
            rules.append(KFilterRule(field: filterField(.priority), isNegated: negated(.priority), valueSummary: joined(names)))
        }
        if !f.efforts.isEmpty {
            let names = f.efforts.compactMap { KEffort(rawValue: $0) }.map(effortName)
            rules.append(KFilterRule(field: filterField(.effort), isNegated: negated(.effort), valueSummary: joined(names)))
        }
        if !f.depths.isEmpty {
            let names = f.depths.compactMap { KDepth(rawValue: $0) }.map(depthName)
            rules.append(KFilterRule(field: filterField(.depth), isNegated: negated(.depth), valueSummary: joined(names)))
        }
        if !f.projectIDs.isEmpty || f.noProject {
            var names = f.projectIDs.compactMap(projectName)
            if f.noProject { names.append(String(localized: "viewoptions.noproject")) }
            rules.append(KFilterRule(field: filterField(.project), isNegated: negated(.project), valueSummary: joined(names)))
        }
        if !f.areaIDs.isEmpty {
            let names = f.areaIDs.compactMap(areaName)
            rules.append(KFilterRule(field: filterField(.area), isNegated: negated(.area), valueSummary: joined(names)))
        }
        if !f.labelIDs.isEmpty {
            let names = f.labelIDs.compactMap(labelName)
            rules.append(KFilterRule(field: filterField(.label), isNegated: negated(.label), valueSummary: joined(names)))
        }
        if f.due != .any {
            rules.append(KFilterRule(field: filterField(.deadline), isNegated: negated(.deadline), valueSummary: deadlineSummary(f)))
        }
        if let v = f.hasSubtasks { rules.append(boolRule(.hasSubtasks, v)) }
        if let v = f.hasNotes { rules.append(boolRule(.hasNotes, v)) }
        if let v = f.isSomeday { rules.append(boolRule(.isSomeday, v)) }
        if let v = f.needsTriage { rules.append(boolRule(.needsTriage, v)) }
        if let v = f.dread { rules.append(boolRule(.dread, v)) }
        if !f.text.isEmpty {
            rules.append(KFilterRule(field: filterField(.text), isNegated: negated(.text), valueSummary: "\"\(f.text)\""))
        }
        return rules
    }

    /// Boolean fields have no negation toggle (spec: "Boolean fields show is / is not as
    /// true/false rather than a second operator") — the value itself is the whole answer.
    private static func boolRule(_ id: FilterFieldID, _ value: Bool) -> KFilterRule {
        KFilterRule(field: filterField(id), valueSummary: value ? "true" : "false")
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
