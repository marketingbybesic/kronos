// Kronos/Palette/PaletteItem.swift
// One filtered, ranked, grouped list mixing registry commands and live task search results —
// the palette shows both under a shared row language (§3.2: "Search" group, query length >= 2).
import Foundation
import KronosCore

enum PaletteItem: Identifiable {
    case command(PaletteCommand)
    case task(KTask)

    var id: String {
        switch self {
        case .command(let c): return "cmd.\(c.id)"
        case .task(let t): return "task.\(t.id)"
        }
    }

    @MainActor
    var group: PaletteGroup {
        switch self {
        case .command(let c): return c.group
        case .task: return .task
        }
    }

    @MainActor
    func run(_ model: AppModel) {
        switch self {
        case .command(let c): c.run(model)
        case .task(let t):
            // A subtask opens its parent's row with the inspector on the subtask.
            let row = t.parent ?? t
            model.openDetails(taskID: t.id)
            if let project = row.project {
                model.scope = .project(project.id)
            } else if KStatus.open.contains(row.status) {
                model.scope = .inbox
            } else {
                model.scope = .all
            }
        }
    }
}

/// One row rank: `nil` sorts out of the results entirely. `order` is the registry's own
/// declared position — the stable tiebreak for equal scores, so an empty query (every command
/// tied at score 0) renders in registry order rather than alphabetical-by-id order.
@MainActor
private struct RankedItem {
    let item: PaletteItem
    let score: Int
    let order: Int
}

@MainActor
enum PaletteResults {
    /// Search-group match cap (spec §3.2: "up to 8 task titles").
    static let maxTaskResults = 8
    /// Every other group's per-group cap (ledger: "max ~8 rows per group").
    static let maxRowsPerGroup = 8
    /// Added to a task's title score inside the group sort so a notes-only hit never outranks one.
    private static let titleTier = 100_000
    /// Rows of the "This task" group shown before anything is typed.
    private static let browsingSelectedRows = 6

    /// Builds the grouped, ranked, capped result list for a query. Empty query returns the
    /// default command set (no task search rows), ranked by group order then title — "recent/
    /// most useful commands" per the ledger, approximated here as the registry's own declared
    /// order since this leaf has no recency store to persist across launches.
    static func groups(query: String, model: AppModel) -> [(group: PaletteGroup, items: [PaletteItem])] {
        // The card asks for the same results several times per render; once per state is enough.
        let key = ResultsKey(query: query, version: model.version, selected: model.selectedTaskID,
                             child: model.inspectedSubtaskID, multi: model.selectedIDs, pinned: model.pinnedFocusTaskID,
                             scopeKey: model.scope.storageKey, chroma: model.chromaMode,
                             blockSuggestion: model.coach.blockSuggestion != nil, timeBlocks: TimeBlocksPrefs.isEnabled)
        if let cached, cached.key == key { return cached.groups }
        let computed = computeGroups(query: query, model: model)
        cached = (key, computed)
        return computed
    }

    private struct ResultsKey: Equatable {
        let query: String
        let version: Int
        let selected: UUID?
        let child: UUID?
        let multi: Set<UUID>
        let pinned: UUID?
        let scopeKey: String
        let chroma: ChromaMode
        let blockSuggestion: Bool
        let timeBlocks: Bool
    }

    /// Forgets the remembered results; the card calls it when it opens, so a new session starts fresh.
    static func invalidate() { cached = nil }
    private static var cached: (key: ResultsKey, groups: [(group: PaletteGroup, items: [PaletteItem])])?

    private static func computeGroups(query: String, model: AppModel) -> [(group: PaletteGroup, items: [PaletteItem])] {
        let commands = PaletteCommands.all(model: model).filter { $0.isAvailable(model) }
        var ranked: [RankedItem] = []
        var bestCommand: Int?
        var bestTaskTitle: Int?
        let browsing = query.trimmingCharacters(in: .whitespaces).isEmpty

        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            ranked = commands.enumerated().map { RankedItem(item: .command($1), score: 0, order: $0) }
        } else {
            for (index, c) in commands.enumerated() {
                if let s = PaletteMatcher.bestScore(query: query, fields: c.searchFields) {
                    ranked.append(RankedItem(item: .command(c), score: s, order: index))
                    bestCommand = max(bestCommand ?? s, s)
                }
            }
            if query.count >= 2 {
                // Subtasks are searchable too (they are never rows of a list, but can be found).
                // Every task is scored before the best eight are kept, so an exact title can never
                // be cut off by its place in the default sort order. Notes are matched below titles.
                let tasks = KTaskSorter.sorted(model.store.allTasksIncludingSubtasks(), by: KSortDescriptor.default)
                let candidates = tasks.map {
                    PaletteTaskCandidate(key: $0.id.uuidString, title: $0.title, notes: $0.notes,
                                         foldedNotes: PaletteNotesIndex.shared.folded(id: $0.id, notes: $0.notes))
                }
                let byKey = Dictionary(tasks.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
                for (rank, hit) in PaletteTaskRanking.top(query: query, candidates: candidates, limit: maxTaskResults).enumerated() {
                    guard let task = byKey[hit.key] else { continue }
                    // Title hits always sort above notes-only hits inside the group.
                    ranked.append(RankedItem(item: .task(task), score: hit.score + (hit.inTitle ? Self.titleTier : 0), order: rank))
                    if hit.inTitle { bestTaskTitle = max(bestTaskTitle ?? hit.score, hit.score) }
                }
            }
        }

        var byGroup: [PaletteGroup: [RankedItem]] = [:]
        for r in ranked { byGroup[r.item.group, default: []].append(r) }

        // Tasks lead when the best task title beats the best command; the bulk group (only present
        // with a multi-selection, Delete last) stays first either way.
        var order = PaletteGroup.allCases
        if PaletteGroupOrder.tasksFirst(bestTaskTitleScore: bestTaskTitle, bestCommandScore: bestCommand) {
            order.removeAll { $0 == .task }
            order.insert(.task, at: order.first == .bulk ? 1 : 0)
        }

        return order.compactMap { group -> (PaletteGroup, [PaletteItem])? in
            guard var rows = byGroup[group], !rows.isEmpty else { return nil }
            rows.sort { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
            // The bulk group is uncapped: Delete is its LAST row (audit D14) and a cap of 8 hid it.
            // With nothing typed, "This task" shows only its first few rows; typing reaches the rest.
            let cap = group == .selected && browsing ? Self.browsingSelectedRows : maxRowsPerGroup
            let capped = Array(group == .bulk ? rows : Array(rows.prefix(cap))).map(\.item)
            return (group, capped)
        }
    }
}

/// Folded notes per task, so a keystroke compares against text folded once, not folded again for
/// every task. An entry is refreshed when the text of the note changes.
@MainActor
final class PaletteNotesIndex {
    static let shared = PaletteNotesIndex()
    private var entries: [UUID: (hash: Int, folded: String)] = [:]
    private init() {}

    func folded(id: UUID, notes: String) -> String {
        guard !notes.isEmpty else { return "" }
        let hash = notes.hashValue
        if let entry = entries[id], entry.hash == hash { return entry.folded }
        let folded = PaletteTaskRanking.foldedNotes(notes)
        entries[id] = (hash, folded)
        return folded
    }
}
