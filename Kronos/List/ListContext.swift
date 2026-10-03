// Kronos/List/ListContext.swift
// One computed snapshot of what the current scope shows: title, options and final rows. The
// header, chips, body, keyboard and the "next" publisher all read the same list, and they read
// ONE build of it per state: `ListContext(model:)` returns the memoised snapshot for the current
// (version, scope, search, options, Earlier open, lingering rows, day); only a change of one of
// those builds again (ListContextMemo).
import SwiftUI
import KronosCore

/// One computed snapshot of "what this scope shows right now" — title, options, final rows —
/// so the header, chips, body and Ordo publisher all read the identical list.
@MainActor
struct ListContext {
    let title: String
    let options: ViewOptions
    let rows: [KTask]
    let activeRuleCount: Int
    /// Labels of a positive label filter. A child carrying one is never a row of its own: its
    /// parent row is listed (KFilter) and the child is marked under it, like a due-driving step
    /// in Today. Empty when no label filter is set or the label field is negated.
    let markedLabelIDs: Set<UUID>
    /// Today only: rows carried from earlier days, shown under the collapsed "Earlier (n)" header.
    let earlier: [KTask]
    /// How many leading entries of `rows` are the scope's own (non-Earlier) rows.
    let currentCount: Int

    /// Rows above the Earlier header.
    var currentRows: ArraySlice<KTask> { rows.prefix(currentCount) }
    /// Earlier rows while the section is open (empty while it is collapsed).
    var openEarlierRows: ArraySlice<KTask> { rows.dropFirst(currentCount) }
    /// Everything the list holds, open section or not (Today is clear only when this is 0).
    var totalCount: Int { currentCount + earlier.count }

    /// The snapshot for the model's current state: built once per state, then shared.
    init(model: AppModel) {
        let key = ListContextKey(model: model)
        self = Self.memo.value(for: key) { ListContext(building: model) }
    }

    private static var memo = ListContextMemo<ListContextKey, ListContext>()
    /// Builds so far in this run (the live scale step reads it: one build per mutation).
    static var builds: Int { memo.builds }

    /// Filters and sorts every task for the current scope. Only the memo calls this.
    private init(building model: AppModel) {
        let scope = model.scope
        // A `.savedView` scope has no base membership of its own (ScopeFilter.matches returns true
        // for every task): until the user edits its options here, `model.options(for:)` answers with
        // the KSavedView's own sort + filter + showDone; an edit is then kept on top of it (and
        // "Update view" writes it back).
        let opts = model.options(for: scope)
        self.options = opts
        self.title = ListContext.title(for: scope, model: model)
        let today = Day.today()

        var filter = opts.filter
        let base = ScopeFilter.baseFilter(for: scope)
        filter.statuses = filter.statuses.isEmpty ? base.statuses : filter.statuses
        if !opts.showCompleted, filter.statuses.isEmpty {
            filter.statuses = KStatus.openRaw
        }
        filter.projectIDs = filter.projectIDs.isEmpty ? base.projectIDs : filter.projectIDs
        filter.areaIDs = filter.areaIDs.isEmpty ? base.areaIDs : filter.areaIDs
        filter.noProject = filter.noProject || base.noProject
        if filter.due == .any { filter.due = base.due }

        let all = model.store.allTasks()
        var matched = all.filter { ScopeFilter.matches($0, scope: scope, today: today) && filter.matches($0, today: today) }
        // A row completed from this list a moment ago stays (struck through) for about a second, so
        // the click visibly lands before the row leaves (ListLinger).
        let lingering = ListLinger.ids(for: scope)
        if !lingering.isEmpty {
            let shown = Set(matched.map(\.id))
            matched += all.filter { lingering.contains($0.id) && !shown.contains($0.id) && $0.status == .done && $0.deletedAt == nil }
        }
        if !model.searchText.isEmpty {
            let needle = KTextFold.fold(model.searchText)
            matched = matched.filter { $0.titleOrSubtaskTitleContains(needle) }
        }
        let sorted = KTaskSorter.sorted(matched, by: opts.sort)
        // Today: carried rows (and rows whose day has passed) move into the Earlier section at
        // the end. `rows` is what is shown, in display order: today's rows, then the Earlier rows
        // only while the section is open, so keyboard, selection and "next" follow the screen.
        if scope == .today {
            let split = TodayPartition.split(rows: sorted, today: today)
            self.earlier = split.earlier
            self.rows = split.current + (ListEarlierState.shared.isExpanded ? split.earlier : [])
            self.currentCount = split.current.count
        } else {
            self.earlier = []
            self.rows = sorted
            self.currentCount = sorted.count
        }
        self.activeRuleCount = ViewOptionsMapper.activeRuleCount(sort: opts.sort, filter: opts.filter)
        self.markedLabelIDs = opts.filter.isNegated(.labels) ? [] : Set(opts.filter.labelIDs)
    }

    private static func title(for scope: ListScope, model: AppModel) -> String {
        if let key = scope.titleKey { return String(localized: String.LocalizationValue(key)) }
        switch scope {
        case .project(let id): return model.store.allProjects().first { $0.id == id }?.name ?? "Project"
        case .area(let id): return model.store.allProjects().compactMap(\.area).first { $0.id == id }?.name ?? "Area"
        case .savedView(let id): return model.store.allSavedViews().first { $0.id == id }?.name ?? "View"
        default: return ""
        }
    }
}

/// Everything a snapshot depends on. Every user write bumps `model.version`; the undo depth also
/// moves on any undoable write (or undo) even before the writer calls `didMutate()`, so a read
/// squeezed between a write and its refresh is never served the old rows.
@MainActor
struct ListContextKey: Equatable {
    let version: Int
    let undoDepth: Int
    let scope: ListScope
    let search: String
    let options: ViewOptions
    let earlierExpanded: Bool
    let lingerGeneration: Int
    let today: Int

    init(model: AppModel) {
        version = model.version
        undoDepth = model.store.undoDepth
        scope = model.scope
        search = model.searchText
        options = model.options(for: model.scope)
        earlierExpanded = ListEarlierState.shared.isExpanded
        lingerGeneration = ListLinger.generation
        today = Day.today()
    }
}

/// Rows completed from a list a moment ago, keyed by the list they were completed in. They stay
/// visible, struck through, for `seconds`; then the list refreshes and they leave.
@MainActor
enum ListLinger {
    static let seconds: Double = 1.0
    private static var entries: [UUID: String] = [:]
    /// Bumped whenever the set of lingering rows changes (part of the snapshot key).
    private(set) static var generation = 0

    static func hold(_ id: UUID, in scope: ListScope, model: AppModel) {
        entries[id] = scope.storageKey
        generation &+= 1
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            guard entries.removeValue(forKey: id) != nil else { return }
            generation &+= 1
            // The row leaving is a refresh, not a write: the completion already raised its pill.
            model.didMutate()   // refresh-only: a lingering row leaves
        }
    }

    static func release(_ id: UUID) {
        guard entries.removeValue(forKey: id) != nil else { return }
        generation &+= 1
    }

    static func ids(for scope: ListScope) -> Set<UUID> {
        let key = scope.storageKey
        return Set(entries.compactMap { $0.value == key ? $0.key : nil })
    }
}
