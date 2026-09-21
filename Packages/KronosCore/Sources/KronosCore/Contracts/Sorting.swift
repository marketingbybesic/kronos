// Part of the frozen contract surface. See Contracts.swift.
//
// Multi-key sorting. A view's ordering is an ordered list of
// `KSortDescriptor`, each with its own direction, applied first-key-first.
//
// Two rules make the result usable rather than merely sorted:
//
//  * NIL / NONE ALWAYS SORTS LAST, in both directions. Flipping to descending
//    must not drag every task with no deadline to the top of the list — the
//    user asked to see the furthest deadline first, not to see the tasks that
//    have no deadline at all. Absence is not an extreme value.
//  * THE ORDER IS TOTAL. After the user's keys are exhausted the comparator
//    falls through to `sortIndex` then `id`, so equal rows never shuffle
//    between renders and the sort is stable without relying on the sort
//    algorithm being stable.

import Foundation

// MARK: - Text folding (shared with KLabel.mergeKey)

public enum KTextFold {
    /// Case- and diacritic-insensitive folding for comparison and search.
    ///
    /// `đ`/`Đ` is mapped to `d`/`D` BEFORE folding, because it is a distinct
    /// Latin letter (d-with-stroke) rather than a base letter plus a
    /// combining mark: `č ć š ž` decompose and fold, `đ` survives folding
    /// unchanged, so `dakovo` would never match `Đakovo`. The folding locale
    /// is pinned to `en_US_POSIX` so results do not vary by region.
    public static func fold(_ s: String) -> String {
        s.replacingOccurrences(of: "đ", with: "d")
         .replacingOccurrences(of: "Đ", with: "D")
         .folding(options: [.caseInsensitive, .diacriticInsensitive],
                  locale: Locale(identifier: "en_US_POSIX"))
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - KSortKey

/// Every sortable field. Raw values are stable wire strings: a saved view
/// persists these, so renaming a case would silently reset a user's sort.
public enum KSortKey: String, Codable, CaseIterable, Sendable {
    /// The global manual order (`sortIndex`). Drag-and-drop writes this.
    case manual
    case title
    case status
    case priority
    case effort
    /// `dueDay`. Called "deadline" in the UI; tasks without one sort last.
    case deadline
    case project
    case area
    /// The task's first label in folded alphabetical order; none sorts last.
    case label
    case createdAt
    case updatedAt
    case completedAt
    case estimateMinutes
    case depth
}

// MARK: - KSortDescriptor

/// One sort key and its direction. A view's ordering is `[KSortDescriptor]`
/// applied in order, the first being primary.
public struct KSortDescriptor: Codable, Equatable, Sendable {
    public var key: KSortKey
    /// Ascending means smallest/earliest/lowest first. It never changes where
    /// nil values land: those are always last.
    public var ascending: Bool

    public init(key: KSortKey, ascending: Bool = true) {
        self.key       = key
        self.ascending = ascending
    }

    public static func asc(_ key: KSortKey) -> KSortDescriptor {
        KSortDescriptor(key: key, ascending: true)
    }
    public static func desc(_ key: KSortKey) -> KSortDescriptor {
        KSortDescriptor(key: key, ascending: false)
    }

    /// The default ordering when a view specifies none.
    public static let `default`: [KSortDescriptor] = [.asc(.manual)]
}

// MARK: - KTaskSorter

/// The one comparator. Pure, synchronous, total and deterministic.
public enum KTaskSorter {

    /// One comparable field value, with absence modelled explicitly so the
    /// "nil last" rule is enforced in one place rather than per key.
    private enum Value {
        case absent
        case int(Int)
        case double(Double)
        case date(Date)
        case text(String)

        var isAbsent: Bool { if case .absent = self { return true }; return false }

        /// Ordering WITHIN the present values only. Absence is handled by the
        /// caller, before direction is applied.
        static func compare(_ a: Value, _ b: Value) -> ComparisonResult {
            switch (a, b) {
            case let (.int(x), .int(y)):
                return x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
            case let (.double(x), .double(y)):
                return x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
            case let (.date(x), .date(y)):
                return x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
            case let (.text(x), .text(y)):
                if x == y { return .orderedSame }
                return x < y ? .orderedAscending : .orderedDescending
            default:
                // Mixed kinds cannot arise: one key yields one kind.
                return .orderedSame
            }
        }
    }

    private static func value(_ t: KTask, _ key: KSortKey) -> Value {
        switch key {
        case .manual:   return .double(t.sortIndex)
        case .title:    return .text(KTextFold.fold(t.title))
        case .status:   return .int(t.statusRaw)
        case .priority: return .int(t.priorityRaw)
        case .effort:
            // .none is "unsized", not "smallest": it sorts last like any
            // other absent value rather than ahead of every xs task.
            return t.effort == .none ? .absent : .int(t.effortRaw)
        case .deadline:
            return t.dueDay.map { Value.int($0) } ?? .absent
        case .project:
            guard let n = t.project?.name, !n.isEmpty else { return .absent }
            return .text(KTextFold.fold(n))
        case .area:
            guard let n = t.project?.area?.name, !n.isEmpty else { return .absent }
            return .text(KTextFold.fold(n))
        case .label:
            let names = (t.labels ?? []).map { KTextFold.fold($0.name) }.sorted()
            guard let first = names.first else { return .absent }
            return .text(first)
        case .createdAt:  return .date(t.createdAt)
        case .updatedAt:  return .date(t.updatedAt)
        case .completedAt:
            return t.completedAt.map { Value.date($0) } ?? .absent
        case .estimateMinutes:
            return t.estimateMinutes.map { Value.int($0) } ?? .absent
        case .depth:
            return t.depth == .unknown ? .absent : .int(t.depthRaw)
        }
    }

    /// Sort `tasks` by `descriptors`, applied in order.
    ///
    /// - Nil / none values sort LAST for every key, in both directions.
    /// - Text keys compare case- and diacritic-insensitively, with `đ` mapped
    ///   to `d` first, so `Đakovo` sorts among the Ds.
    /// - After the descriptors are exhausted the order falls through to
    ///   `sortIndex` then `id`, making it total: the result is identical on
    ///   every call for the same input.
    /// - An empty `descriptors` list sorts by that final tiebreak alone.
    public static func sorted(_ tasks: [KTask],
                              by descriptors: [KSortDescriptor]) -> [KTask] {
        tasks.sorted { a, b in
            for d in descriptors {
                let va = value(a, d.key)
                let vb = value(b, d.key)

                // Absence is not an extreme: it is always last, whichever
                // direction the user picked.
                switch (va.isAbsent, vb.isAbsent) {
                case (true, true):  continue
                case (true, false): return false
                case (false, true): return true
                case (false, false): break
                }

                switch Value.compare(va, vb) {
                case .orderedSame:       continue
                case .orderedAscending:  return d.ascending
                case .orderedDescending: return !d.ascending
                }
            }
            // Total-order tiebreak, direction-independent.
            if a.sortIndex != b.sortIndex { return a.sortIndex < b.sortIndex }
            return a.id.uuidString < b.id.uuidString
        }
    }
}
