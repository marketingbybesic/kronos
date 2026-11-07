// Which of a task row's optional trailing columns (richest first: recurrence, subtasks, the
// project glyph) a list currently has room to show — and, just as importantly, which of them it
// actually NEEDS. A list whose visible rows never set a value for a column must not reserve
// that column's width anyway: the row's title gets to keep it instead of sitting beside empty
// slots (Kronos/List/ListRowView.swift's `ColumnMode`, Kronos/List/TaskListScreen.swift's
// per-build budget). Pure so the picking rule is table-tested without a live window.

import Foundation

public enum ColumnBudget {
    /// `widths` holds one total trailing-slot width per richness level, STRICTLY ASCENDING from
    /// index 0 (nothing optional shown) to `widths.count - 1` (every optional column shown) —
    /// Kronos/List/ListRowView.swift's `SlotWidth.totalWidth(for:)` supplies the real numbers,
    /// in that same order, for the real four `ColumnMode` cases.
    ///
    /// Picks the SMALLEST level that still shows every column `neededLevel` requires (never
    /// more — an unused column is never reserved just because the window could fit it), then
    /// falls back toward 0 only as far as `available` forces it to (the original behaviour when
    /// even the needed columns do not fit).
    public static func pick(available: Double, widths: [Double], neededLevel: Int) -> Int {
        guard !widths.isEmpty else { return 0 }
        var level = min(max(neededLevel, 0), widths.count - 1)
        while level > 0 && widths[level] > available { level -= 1 }
        return level
    }
}
