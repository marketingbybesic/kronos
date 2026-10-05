// What a list OFFERS in its view-options editor: the sort keys and filter fields that are meaningful
// there, and the rule for dropping stored ones that no longer are.
//
// The sort and filter MODEL (KSortKey, KFilter) keeps every key and field, because saved views and
// stored options use them. This catalog only decides what the editor lists:
//
//  * a list shows rows that already agree on a field (a project list on "Project", a Waiting list on
//    "Status"), so that field is not offered there: sorting or filtering by it could only do nothing
//    or contradict the list;
//  * "Manual" is the default order, not a criterion to add (Clear all is the way back);
//  * Area, Label and Depth are not sort keys worth offering (area is the project's area, a label
//    key is "first label alphabetically", depth is unknown for almost every task);
//  * Depth, Avoiding it and Someday are not filter fields (depth is almost always unknown, "Avoiding
//    it" is a coach flag, and Someday duplicates Status).
//
// Pure and synchronous so the whole table is unit-tested.

import Foundation

/// The kind of list an options edit is made on. Built from the app's scope (Waiting and Someday
/// hold one status each, a project or an area is its own container, a saved view is its own rule).
public struct ListShape: Equatable, Sendable {
    public var isProject: Bool
    public var isArea: Bool
    public var isSavedView: Bool
    /// The one status every member of the list has (Waiting, Someday), else nil.
    public var fixedStatus: KStatus?

    public init(isProject: Bool = false, isArea: Bool = false, isSavedView: Bool = false, fixedStatus: KStatus? = nil) {
        self.isProject = isProject
        self.isArea = isArea
        self.isSavedView = isSavedView
        self.fixedStatus = fixedStatus
    }

    /// Inbox, Today, Next 7 days, All.
    public static let global = ListShape()
    public static let project = ListShape(isProject: true)
    public static let area = ListShape(isArea: true)
    public static let savedView = ListShape(isSavedView: true)
    public static let waiting = ListShape(fixedStatus: .waiting)
    public static let someday = ListShape(fixedStatus: .someday)

    /// Whether "Show completed" means anything here: a Waiting or Someday list holds no closed task.
    public var offersShowCompleted: Bool { fixedStatus == nil }
}

public enum ViewFieldCatalog {

    /// The sort keys the editor offers, in menu order. Never includes `.manual`.
    public static func sortKeys(for shape: ListShape, showCompleted: Bool) -> [KSortKey] {
        var keys: [KSortKey] = [.title]
        if shape.fixedStatus == nil { keys.append(.status) }
        keys += [.priority, .effort, .deadline]
        if !shape.isProject { keys.append(.project) }
        keys += [.createdAt, .updatedAt, .estimateMinutes]
        if showCompleted && shape.offersShowCompleted { keys.append(.completedAt) }
        return keys
    }

    /// The filter fields the editor offers to ADD, in menu order.
    public static func filterFields(for shape: ListShape) -> [KFilter.Field] {
        var fields: [KFilter.Field] = []
        if shape.fixedStatus == nil { fields.append(.statuses) }
        fields += [.priorities, .efforts]
        if !shape.isProject { fields.append(.project) }
        if !shape.isProject && !shape.isArea { fields.append(.area) }
        fields += [.labels, .due, .hasSubtasks, .hasNotes, .needsTriage, .text]
        return fields
    }

    /// `opts` without the sort keys and filter fields that `shape` does not offer: what a list built
    /// before the catalog (or on another kind of list) may still have stored. A saved view keeps
    /// every rule it has: it is the person's own definition and still filters and sorts by it.
    public static func sanitized(_ opts: ViewOptions, for shape: ListShape) -> ViewOptions {
        guard !shape.isSavedView else { return opts }
        var out = opts

        let offeredSort = Set(sortKeys(for: shape, showCompleted: opts.showCompleted))
        let keptSort = opts.sort.filter { offeredSort.contains($0.key) }
        out.sort = keptSort.isEmpty ? KSortDescriptor.default : keptSort

        let offered = Set(filterFields(for: shape))
        for field in KFilter.Field.allCases where !offered.contains(field) {
            out.filter.clear(field)
        }
        return out
    }
}

extension KFilter {
    /// Removes the constraint on one field (and its inversion), leaving every other field alone.
    public mutating func clear(_ field: Field) {
        switch field {
        case .statuses: statuses = []
        case .priorities: priorities = []
        case .efforts: efforts = []
        case .depths: depths = []
        case .project: projectIDs = []; noProject = false
        case .area: areaIDs = []
        case .labels: labelIDs = []
        case .due: due = .any; dueFrom = nil; dueTo = nil
        case .dread: dread = nil
        case .hasNotes: hasNotes = nil
        case .hasSubtasks: hasSubtasks = nil
        case .isSomeday: isSomeday = nil
        case .needsTriage: needsTriage = nil
        case .text: text = ""
        }
        setNegated(field, false)
    }
}
