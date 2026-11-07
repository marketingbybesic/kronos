// Whether Flow's column grid needs horizontal scroll (E6: "vertical scroll always; horizontal
// scroll only past 4 columns. No pan or zoom"). The real test is not a raw column count — a
// narrow pane (the inspector open, a smaller window) can overflow at 2 or 3 columns too, and a
// wide one may never need it even past 4 — it is whether the columns' fixed content width
// actually exceeds the VISIBLE pane. Pure so the decision is table-tested without a live window.

import Foundation

public enum FlowColumnScroll {
    /// `cardWidth`/`columnGap`/`horizontalPadding` are the same fixed numbers the view itself
    /// lays out with (Kronos/DesignSystem/Tokens.swift's `flowCardWidth`/`flowColumnGap`, and
    /// the grid's own horizontal padding) — passed in rather than read here so this stays a
    /// plain function of its inputs.
    public static func needsHorizontalScroll(columnCount: Int, cardWidth: Double, columnGap: Double,
                                              horizontalPadding: Double, available: Double) -> Bool {
        guard columnCount > 0 else { return false }
        let n = Double(columnCount)
        let contentWidth = n * cardWidth + max(0, n - 1) * columnGap + horizontalPadding
        return contentWidth > available
    }
}
