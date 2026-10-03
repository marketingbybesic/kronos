// Search over a list of top-level tasks: a task is found by its own title and also by the title
// of one of its live subtasks, because the subtasks are never rows of their own. The row that
// answers is the parent; the palette (which can list subtasks) opens the subtask itself.

import Foundation

extension KTask {

    /// True when the title of this task, or of one of its live subtasks, contains
    /// `foldedNeedle` (already folded with `KTextFold.fold`). An empty needle matches nothing.
    public func titleOrSubtaskTitleContains(_ foldedNeedle: String) -> Bool {
        guard !foldedNeedle.isEmpty else { return false }
        if KTextFold.fold(title).contains(foldedNeedle) { return true }
        return orderedChildren.contains { KTextFold.fold($0.title).contains(foldedNeedle) }
    }

    /// True when this task itself carries at least one of `labelIDs`.
    public func carriesAnyLabel(of labelIDs: Set<UUID>) -> Bool {
        guard !labelIDs.isEmpty else { return false }
        return (labels ?? []).contains { labelIDs.contains($0.id) }
    }

    /// The live children carrying at least one of `labelIDs`, in manual order. A label filter
    /// shows the parent row and marks these children (they are never rows of their own).
    public func childrenCarryingAnyLabel(of labelIDs: Set<UUID>) -> [KTask] {
        guard !labelIDs.isEmpty else { return [] }
        return orderedChildren.filter { $0.carriesAnyLabel(of: labelIDs) }
    }

    /// The label-filter answer for a row: the task or one of its live children carries a label.
    public func selfOrChildCarriesAnyLabel(of labelIDs: Set<UUID>) -> Bool {
        carriesAnyLabel(of: labelIDs) || !childrenCarryingAnyLabel(of: labelIDs).isEmpty
    }
}
