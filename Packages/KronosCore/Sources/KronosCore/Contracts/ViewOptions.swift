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
    /// "Group by" (spec §4.5-4.6): sections the list into sticky-header groups instead of one
    /// flat run. `.none` is today's rendering.
    public var groupBy: KGroupBy = .none

    public init(sort: [KSortDescriptor] = KSortDescriptor.default,
                filter: KFilter = .empty,
                showCompleted: Bool = false,
                groupBy: KGroupBy = .none) {
        self.sort = sort
        self.filter = filter
        self.showCompleted = showCompleted
        self.groupBy = groupBy
    }

    /// Tolerant decode, same pattern as `KFilter.init(from:)` (Filtering.swift): a `ViewOptions`
    /// blob persisted before `groupBy` existed decodes to `.none` instead of throwing. It must
    /// not throw at all — `UIContract.persist()` decodes every scope's options in one
    /// `[String: ViewOptions]` blob, so one throw here would silently reset every list's sort
    /// and filter too, not just leave grouping off.
    private enum CodingKeys: String, CodingKey { case sort, filter, showCompleted, groupBy }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Each field decodes with its own `try?`, not the container's `try`: a corrupt value for
        // one field (wrong type, or — `groupBy` — a raw value no longer in `KGroupBy`) degrades
        // just that field to its default, same as a missing key, instead of throwing and losing
        // every other field in the same blob (the doc comment above).
        sort = (try? c.decodeIfPresent([KSortDescriptor].self, forKey: .sort)) ?? KSortDescriptor.default
        filter = (try? c.decodeIfPresent(KFilter.self, forKey: .filter)) ?? .empty
        showCompleted = (try? c.decodeIfPresent(Bool.self, forKey: .showCompleted)) ?? false
        // Decoded as the raw Int rather than `KGroupBy` directly: a synthesized RawRepresentable
        // decoder throws on a value with no matching case (an older/newer build's raw value, or a
        // corrupt write), which `decodeIfPresent(KGroupBy.self, ...)` would propagate exactly like
        // a type mismatch — the blob-wide throw this initializer exists to avoid.
        let groupByRaw = try? c.decodeIfPresent(Int.self, forKey: .groupBy)
        groupBy = groupByRaw.flatMap(KGroupBy.init(rawValue:)) ?? .none
    }

    public static let `default` = ViewOptions()

    /// The list shows the person's own (dragged) order: the only order a drag can change.
    public var isManualOrder: Bool { sort == KSortDescriptor.default }

    /// True when any sort other than manual, or any filter, is set: what "Clear all" would
    /// remove. "Show completed" is a display switch, not a rule, so it never counts.
    public var hasRulesToClear: Bool { !isManualOrder || filter != .empty }

    /// Every sort and filter removed; the display switches (including grouping) are kept.
    public func cleared() -> ViewOptions {
        ViewOptions(sort: KSortDescriptor.default, filter: .empty, showCompleted: showCompleted, groupBy: groupBy)
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
