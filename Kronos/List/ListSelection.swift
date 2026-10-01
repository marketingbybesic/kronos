// Kronos/List/ListSelection.swift
// Pure multi-selection rules for the task list (no SwiftUI, no store): the screen feeds it the
// visible row order and gets the new selection back. Kept Foundation-only so
// scripts/bulk-selftest.swift can compile THIS file against hand-written cases.
// Invariant: the multi set is either empty (single selection) or holds 2+ ids INCLUDING the
// anchor (`selectedTaskID`), so the inspector always shows a row that is part of the set.
import Foundation

struct ListSelectionState: Equatable {
    var anchor: UUID?
    var ids: Set<UUID>
}

enum ListSelection {
    /// Collapses a 0/1-element set to "no multi-selection" and drops a set that lost its anchor.
    static func normalized(_ s: ListSelectionState) -> ListSelectionState {
        guard s.ids.count > 1, let a = s.anchor, s.ids.contains(a) else {
            return ListSelectionState(anchor: s.anchor ?? s.ids.first, ids: [])
        }
        return s
    }

    /// ⌘-click: flips one row. The anchor joins the set first, so ⌘-clicking a second row
    /// after a plain click selects BOTH (not just the new one).
    static func toggle(_ id: UUID, from s: ListSelectionState, rows: [UUID]) -> ListSelectionState {
        var ids = s.ids.isEmpty ? Set([s.anchor].compactMap { $0 }) : s.ids
        var anchor = s.anchor
        if ids.contains(id) {
            ids.remove(id)
            if anchor == id { anchor = rows.first { ids.contains($0) } }
        } else {
            ids.insert(id)
            anchor = id
        }
        return normalized(ListSelectionState(anchor: anchor, ids: ids))
    }

    /// ⇧-click: every row from the anchor to the clicked one, inclusive, in visible order. The
    /// anchor stays put so a second ⇧-click re-ranges from the same row. No usable anchor:
    /// behaves like a plain click.
    static func range(to id: UUID, from s: ListSelectionState, rows: [UUID]) -> ListSelectionState {
        guard let a = s.anchor, let i = rows.firstIndex(of: a), let j = rows.firstIndex(of: id) else {
            return ListSelectionState(anchor: id, ids: [])
        }
        return normalized(ListSelectionState(anchor: a, ids: Set(rows[min(i, j)...max(i, j)])))
    }

    /// ⌘A. Never while a text field owns the keyboard (nil = do nothing, let the field select
    /// its own text). The anchor survives if it is visible, else the first row takes over.
    static func selectAll(from s: ListSelectionState, rows: [UUID], isTyping: Bool) -> ListSelectionState? {
        guard !isTyping, !rows.isEmpty else { return nil }
        let anchor = s.anchor.flatMap { rows.contains($0) ? $0 : nil } ?? rows[0]
        return normalized(ListSelectionState(anchor: anchor, ids: Set(rows)))
    }

    /// Drops ids that are no longer visible (scope change, filter, completion, delete).
    static func pruned(_ s: ListSelectionState, rows: [UUID]) -> ListSelectionState {
        let visible = Set(rows)
        var anchor = s.anchor
        let ids = s.ids.intersection(visible)
        if let a = anchor, !ids.contains(a), ids.count > 1 { anchor = rows.first { ids.contains($0) } }
        return normalized(ListSelectionState(anchor: anchor, ids: ids))
    }
}
