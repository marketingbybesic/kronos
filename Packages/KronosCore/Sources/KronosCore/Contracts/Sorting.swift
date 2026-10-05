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
    /// `effectiveDue` (own day, or an earlier undone subtask day). Called "deadline" in the UI; tasks without one sort last.
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
            return t.effectiveDue.map { Value.int($0) } ?? .absent
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

    /// True when `task` has no value for `key` (the rows the sorter always puts last). Priority is
    /// never absent: "none" is a real, comparable priority.
    public static func isAbsent(_ task: KTask, _ key: KSortKey) -> Bool {
        value(task, key).isAbsent
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

// MARK: - Missing-value group

/// A list sorted by an attribute shows the tasks that LACK it as their own group at the bottom
/// (the sorter already puts them last), and offers to suggest the value for them.
public enum SortGrouping {

    /// The field triage fills for a sort key, nil for a key whose absence is not something to fill
    /// (manual, title, status, dates of creation; priority is never absent).
    public static func fillKind(for key: KSortKey) -> TriageFieldKind? {
        switch key {
        case .deadline: return .due
        case .effort: return .effort
        case .estimateMinutes: return .estimateMinutes
        case .depth: return .depth
        case .project: return .project
        case .label: return .labels
        default: return nil
        }
    }

    /// The key whose missing tasks get their own group: the FIRST sort key, when it is one with a
    /// fill field. Nil for a manual order or a key without one.
    public static func missingKey(for sort: [KSortDescriptor]) -> KSortKey? {
        guard let first = sort.first, fillKind(for: first.key) != nil else { return nil }
        return first.key
    }

    /// `rows` (already sorted) split into the rows that have a value for `key` and those that lack
    /// it. Each part keeps the order it had.
    public static func split(rows: [KTask], key: KSortKey) -> (present: [KTask], missing: [KTask]) {
        var present: [KTask] = [], missing: [KTask] = []
        for row in rows {
            if KTaskSorter.isAbsent(row, key) { missing.append(row) } else { present.append(row) }
        }
        return (present, missing)
    }
}

/// One proposed value for one task. Nothing is written until the person accepts it.
public struct MissingSuggestion: Equatable, Sendable {
    public enum Value: Equatable, Sendable {
        case due(day: Int)
        case effort(KEffort)
        case estimateMinutes(Int)
        case project(name: String)
    }
    public let taskID: UUID
    public let kind: TriageFieldKind
    public let value: Value
    /// The triage result this was read from; accepting applies it with `only: [kind]`.
    public let result: TriageResult
    /// The model that answered, nil when the neighbour vote did.
    public let modelID: String?

    public var isNeighbourSourced: Bool { modelID == nil }
}

/// The suggestion engine behind "Suggest" in the missing group: the existing triage pipeline run
/// for one field of many tasks. The neighbour vote answers first and works with AI off; when a
/// router is given its answer replaces the vote. A value is proposed only when the pipeline really
/// decided it (a vote placeholder is never a suggestion), and never for a locked field.
public enum MissingSuggest {

    /// What the engine needs from one task (a task is a reference type: this crosses tasks safely).
    public struct Subject: Sendable {
        public let id: UUID
        public let title: String
        public let notes: String
        public let locked: Set<TriageFieldKind>
        public init(id: UUID, title: String, notes: String, locked: Set<TriageFieldKind>) {
            self.id = id; self.title = title; self.notes = notes; self.locked = locked
        }
    }

    /// At most this many tasks are asked about at once, and in one batch.
    public static let batchLimit = 20
    private static let parallel = 3

    public static func suggest(for subjects: [Subject],
                               kind: TriageFieldKind,
                               examples: [(id: UUID, source: TriageExampleSource)],
                               projectNames: [String],
                               labelNames: [String],
                               today: Int,
                               router: (any AIRouting)?,
                               modelID: String?) async -> [MissingSuggestion] {
        let wanted = subjects.filter { !$0.locked.contains(kind) }.prefix(batchLimit)
        var out: [UUID: MissingSuggestion] = [:]
        var index = wanted.startIndex
        while index < wanted.endIndex {
            let end = wanted.index(index, offsetBy: parallel, limitedBy: wanted.endIndex) ?? wanted.endIndex
            let chunk = Array(wanted[index..<end])
            await withTaskGroup(of: MissingSuggestion?.self) { group in
                for subject in chunk {
                    group.addTask {
                        await one(subject, kind: kind, examples: examples, projectNames: projectNames,
                                  labelNames: labelNames, today: today, router: router, modelID: modelID)
                    }
                }
                for await s in group { if let s { out[s.taskID] = s } }
            }
            index = end
        }
        return wanted.compactMap { out[$0.id] }
    }

    private static func one(_ subject: Subject, kind: TriageFieldKind,
                            examples: [(id: UUID, source: TriageExampleSource)],
                            projectNames: [String], labelNames: [String], today: Int,
                            router: (any AIRouting)?, modelID: String?) async -> MissingSuggestion? {
        let context = TriageContextBuilder.build(for: subject.title, notes: subject.notes,
                                                 from: examples.filter { $0.id != subject.id }.map(\.source))
        var result = NeighbourTriage.infer(title: subject.title, notes: subject.notes, context: context, today: today)
        let neighbourFields = NeighbourTriage.fillableFields(title: subject.title, notes: subject.notes,
                                                             context: context, today: today)
        var answeredBy: String? = nil
        if let router,
           let ai = try? await router.triage(title: subject.title, notes: subject.notes, projectNames: projectNames,
                                             labelNames: labelNames, today: today,
                                             lockedFields: Set(subject.locked.map(\.rawValue)), context: context),
           !ai.isDeterministic {
            result = ai
            answeredBy = modelID ?? "ai"
        }
        // A vote carries neutral placeholders for what it did not decide: only a decided field counts.
        if answeredBy == nil, !neighbourFields.contains(kind) { return nil }
        guard let value = value(of: kind, in: result) else { return nil }
        return MissingSuggestion(taskID: subject.id, kind: kind, value: value, result: result, modelID: answeredBy)
    }

    private static func value(of kind: TriageFieldKind, in result: TriageResult) -> MissingSuggestion.Value? {
        switch kind {
        case .due:
            guard let iso = result.due, let day = Day.parseISO(iso) else { return nil }
            return .due(day: day)
        case .effort:
            guard let e = result.effort, e != .none else { return nil }
            return .effort(e)
        case .estimateMinutes:
            return result.estimateMinutes > 0 ? .estimateMinutes(result.estimateMinutes) : nil
        case .project:
            guard let name = result.project, !name.isEmpty else { return nil }
            return .project(name: name)
        default:
            return nil
        }
    }

    /// Writes the accepted suggestions in ONE undo step: each through `applyTriage` limited to its own
    /// field, fill-only, locked fields untouched. Returns the ids that were actually filled.
    @MainActor @discardableResult
    public static func apply(_ suggestions: [MissingSuggestion], to store: any TaskStoring) -> [UUID] {
        var filled: [UUID] = []
        store.groupedUndo("Sort") {
            for s in suggestions {
                let written = store.applyTriage(s.result, to: s.taskID, fillOnly: true, only: [s.kind])
                guard !written.isEmpty else { continue }
                store.recordTriageFill(task: s.taskID, fields: written, model: s.modelID ?? "neighbours")
                filled.append(s.taskID)
            }
        }
        return filled
    }
}
