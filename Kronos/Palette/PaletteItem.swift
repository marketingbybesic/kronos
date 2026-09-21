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
            model.selectedTaskID = t.id
            if let project = t.project {
                model.scope = .project(project.id)
            } else if KStatus.open.contains(t.status) {
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

    /// Builds the grouped, ranked, capped result list for a query. Empty query returns the
    /// default command set (no task search rows), ranked by group order then title — "recent/
    /// most useful commands" per the ledger, approximated here as the registry's own declared
    /// order since this leaf has no recency store to persist across launches.
    static func groups(query: String, model: AppModel) -> [(group: PaletteGroup, items: [PaletteItem])] {
        let commands = PaletteCommands.all(model: model).filter { $0.isAvailable(model) }
        var ranked: [RankedItem] = []

        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            ranked = commands.enumerated().map { RankedItem(item: .command($1), score: 0, order: $0) }
        } else {
            for (index, c) in commands.enumerated() {
                if let s = PaletteMatcher.bestScore(query: query, fields: [c.title, c.group.titleKey]) {
                    ranked.append(RankedItem(item: .command(c), score: s, order: index))
                }
            }
            if query.count >= 2 {
                let tasks = KTaskSorter.sorted(model.store.allTasks(), by: KSortDescriptor.default)
                var found = 0
                for (index, t) in tasks.enumerated() {
                    guard found < maxTaskResults else { break }
                    if let s = PaletteMatcher.score(query: query, haystack: t.title) {
                        ranked.append(RankedItem(item: .task(t), score: s, order: index))
                        found += 1
                    }
                }
            }
        }

        var byGroup: [PaletteGroup: [RankedItem]] = [:]
        for r in ranked { byGroup[r.item.group, default: []].append(r) }

        return PaletteGroup.allCases.compactMap { group -> (PaletteGroup, [PaletteItem])? in
            guard var rows = byGroup[group], !rows.isEmpty else { return nil }
            rows.sort { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
            let capped = Array(rows.prefix(maxRowsPerGroup)).map(\.item)
            return (group, capped)
        }
    }
}
