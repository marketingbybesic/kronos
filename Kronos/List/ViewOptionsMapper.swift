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

    /// `[KSortRule]` -> `[KSortDescriptor]`. "Manual" is exclusive (spec): if the caller
    /// picked Manual, every other rule is dropped, matching the popover's own behaviour
    /// where choosing Manual removes the other rows.
    static func descriptors(from rules: [KSortRule]) -> [KSortDescriptor] {
        if let manual = rules.first(where: { sortKey($0.field) == .manual }) {
            return [KSortDescriptor(key: .manual, ascending: manual.ascending)]
        }
        return rules.map { KSortDescriptor(key: sortKey($0.field), ascending: $0.ascending) }
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
        // GAP (reported): no catalog key for "Next 30 days" / "Custom range" — every other
        // deadline window has one (list.filter.due.*), these two do not.
        case .next30: return "Next 30 days"
        case .none: return String(localized: "list.filter.due.none")
        case .custom:
            guard let from = f.dueFrom, let to = f.dueTo else { return "Custom range" }
            return "\(Day.iso(from)) – \(Day.iso(to))"
        }
    }

    // MARK: - Filter rules <-> KFilter

    /// Which filter rows a `KFilter` implies, in a stable field order, for rebuilding the
    /// builder's `[KFilterRule]` after a KFilter is loaded (scope switch, saved view open).
    /// `isNegated` on each rule mirrors `f.isNegated(_:)` for that rule's Core field — a
    /// boolean-field rule (`coreField` returns nil for those) never negates, since its
    /// true/false value already answers "is"/"is not".
    static func filterRules(from f: KFilter, projectName: (UUID) -> String?, areaName: (UUID) -> String?, labelName: (UUID) -> String?) -> [KFilterRule] {
        var rules: [KFilterRule] = []
        func negated(_ id: FilterFieldID) -> Bool {
            coreField(id).map(f.isNegated) ?? false
        }
        if !f.statuses.isEmpty {
            let names = f.statuses.compactMap { KStatus(rawValue: $0) }.map(statusName)
            rules.append(KFilterRule(field: filterField(.status), isNegated: negated(.status), valueSummary: names.joined(separator: ", ")))
        }
        if !f.priorities.isEmpty {
            let names = f.priorities.compactMap { KPriority(rawValue: $0) }.map(priorityName)
            rules.append(KFilterRule(field: filterField(.priority), isNegated: negated(.priority), valueSummary: names.joined(separator: ", ")))
        }
        if !f.efforts.isEmpty {
            let names = f.efforts.compactMap { KEffort(rawValue: $0) }.map(effortName)
            rules.append(KFilterRule(field: filterField(.effort), isNegated: negated(.effort), valueSummary: names.joined(separator: ", ")))
        }
        if !f.depths.isEmpty {
            let names = f.depths.compactMap { KDepth(rawValue: $0) }.map(depthName)
            rules.append(KFilterRule(field: filterField(.depth), isNegated: negated(.depth), valueSummary: names.joined(separator: ", ")))
        }
        if !f.projectIDs.isEmpty || f.noProject {
            var names = f.projectIDs.compactMap(projectName)
            if f.noProject { names.append(String(localized: "viewoptions.noproject")) }
            rules.append(KFilterRule(field: filterField(.project), isNegated: negated(.project), valueSummary: names.joined(separator: ", ")))
        }
        if !f.areaIDs.isEmpty {
            let names = f.areaIDs.compactMap(areaName)
            rules.append(KFilterRule(field: filterField(.area), isNegated: negated(.area), valueSummary: names.joined(separator: ", ")))
        }
        if !f.labelIDs.isEmpty {
            let names = f.labelIDs.compactMap(labelName)
            rules.append(KFilterRule(field: filterField(.label), isNegated: negated(.label), valueSummary: names.joined(separator: ", ")))
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
