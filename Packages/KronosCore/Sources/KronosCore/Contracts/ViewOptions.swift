// Sort + filter + display options of one list, and the pure rules for editing them.
//
// A list's order is `[KSortDescriptor]`; "manual" is the order the person set by dragging
// (`sortIndex`, children in their own step order) and is the default. Every edit of a
// view's options goes through the functions here so the rules live in one tested place:
//
//  * adding a sort criterion to a manual list REPLACES manual (a manual key in front of
//    another key would make the other key a tie-breaker that never ties, i.e. dead);
//  * picking manual removes every other criterion;
//  * "clear all" drops every sort and filter and nothing else, so the list falls back to
//    the stored manual order without a single row having been rewritten.

import Foundation

public struct ViewOptions: Codable, Equatable, Sendable {
    public var sort: [KSortDescriptor] = KSortDescriptor.default
    public var filter: KFilter = .empty
    public var showCompleted: Bool = false

    public init(sort: [KSortDescriptor] = KSortDescriptor.default,
                filter: KFilter = .empty,
                showCompleted: Bool = false) {
        self.sort = sort
        self.filter = filter
        self.showCompleted = showCompleted
    }

    public static let `default` = ViewOptions()

    /// The list shows the person's own (dragged) order: the only order a drag can change.
    public var isManualOrder: Bool { sort == KSortDescriptor.default }

    /// True when any sort other than manual, or any filter, is set: what "Clear all" would
    /// remove. "Show completed" is a display switch, not a rule, so it never counts.
    public var hasRulesToClear: Bool { !isManualOrder || filter != .empty }

    /// Every sort and filter removed; the display switch is kept.
    public func cleared() -> ViewOptions {
        ViewOptions(sort: KSortDescriptor.default, filter: .empty, showCompleted: showCompleted)
    }

    /// Manual order again, filters untouched (what a drag in a sorted list offers).
    public func switchedToManual() -> ViewOptions {
        var copy = self
        copy.sort = KSortDescriptor.default
        return copy
    }

    /// These options after the sort editor produced `proposed` (its rows, in order).
    ///
    /// `proposed` may hold manual next to other criteria, because the editor lists the
    /// current manual order as a row. Which one wins depends on what changed:
    ///  * manual was already the order and a criterion was added: the criteria win;
    ///  * manual was just picked (it was not in the list before): manual wins alone;
    ///  * nothing left: manual.
    public func replacingSort(with proposed: [KSortDescriptor]) -> ViewOptions {
        var copy = self
        copy.sort = Self.resolveSort(previous: sort, proposed: proposed)
        return copy
    }

    public static func resolveSort(previous: [KSortDescriptor], proposed: [KSortDescriptor]) -> [KSortDescriptor] {
        guard !proposed.isEmpty else { return KSortDescriptor.default }
        guard let manual = proposed.first(where: { $0.key == .manual }) else { return proposed }
        let others = proposed.filter { $0.key != .manual }
        if others.isEmpty { return [manual] }
        let manualWasThere = previous.contains { $0.key == .manual }
        return manualWasThere ? others : [manual]
    }
}
