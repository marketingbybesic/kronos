// Kronos/List/ListColumnMode.swift
// The list-wide trailing-column decision (ColumnMode) and what the visible rows actually need
// (ColumnNeeds) — split from ListRowView.swift to keep it under the 500-line budget
// (gate-files.mjs). Fitting math lives in KronosCore's ColumnBudget.pick.
import Foundation
import KronosCore
/// Which optional trailing slots the list currently has room for. Computed ONCE for the
/// whole list from its measured width (TaskListScreen, via GeometryReader) and passed down
/// to every row — never decided per row. Per-row fitting (e.g. `ViewThatFits` per instance)
/// let two rows in the same list independently choose different variants depending on their
/// OWN content width, which broke column alignment exactly like the unconstrained slot
/// widths did: two rows must always agree on which columns exist.
enum ColumnMode: Equatable {
    case full           // recurrence + subtasks + project
    case noRecurrence    // subtasks + project
    case noSubtasks      // project only
    case minimal         // none of the three
    /// Ascending richness (0 = nothing optional, last = everything) — the order `ColumnBudget.pick` (KronosCore) picks a level from.
    private static let ascending: [ColumnMode] = [.minimal, .noSubtasks, .noRecurrence, .full]

    var showsRecurrence: Bool { self == .full }
    var showsSubtasks: Bool { self == .full || self == .noRecurrence }
    var showsProject: Bool { self != .minimal }

    /// Picks the richest mode that fits `available` without reserving a column `needs` does not
    /// use (a lone Inbox row keeps that width for its title); falls back toward `.minimal`
    /// only as far as `available` forces. Level math is `ColumnBudget.pick` (KronosCore).
    static func fitting(available: CGFloat, needs: ColumnNeeds = .all) -> ColumnMode {
        let neededLevel = ascending.firstIndex { needs.satisfied(by: $0) } ?? ascending.count - 1
        let widths = ascending.map { Double(SlotWidth.totalWidth(for: $0)) }
        let level = ColumnBudget.pick(available: Double(available), widths: widths, neededLevel: neededLevel)
        return ascending[level]
    }
}

/// Which optional trailing columns the list's VISIBLE rows (`TaskListScreen`'s `ctx.rows`) actually hold a value for — what `ColumnMode.fitting` budgets against.
struct ColumnNeeds: Equatable {
    var recurrence = false
    var subtasks = false
    var project = false
    static let all = ColumnNeeds(recurrence: true, subtasks: true, project: true)
    fileprivate func satisfied(by mode: ColumnMode) -> Bool {
        (!recurrence || mode.showsRecurrence) && (!subtasks || mode.showsSubtasks) && (!project || mode.showsProject)
    }
}

