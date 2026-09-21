// Kronos/Palette/PaletteMatcher.swift
// Pure fuzzy/subsequence matcher over folded text. No SwiftUI, no KronosCore model — a
// separately testable type per the brief. Folding (case + diacritics + đ→d) is delegated
// to KronosCore's KTextFold so palette matching stays identical to search/sort elsewhere.
import KronosCore

enum PaletteMatcher {
    /// Subsequence match of `query` inside `haystack` (both already folded by the caller
    /// is NOT required — this folds internally so every call site stays simple).
    /// Returns nil when `query`'s characters do not all appear, in order, in `haystack`.
    /// The score rewards prefix matches, contiguous runs and matches near the start,
    /// mirroring how VS Code / Alfred style pickers rank results.
    static func score(query: String, haystack: String) -> Int? {
        let q = KTextFold.fold(query)
        if q.isEmpty { return 0 }
        let h = KTextFold.fold(haystack)
        if h.hasPrefix(q) { return 1000 - h.count }

        let hChars = Array(h)
        var qi = q.startIndex
        var score = 0
        var runLength = 0
        var firstMatchIndex = -1

        for (i, ch) in hChars.enumerated() {
            guard qi < q.endIndex else { break }
            if ch == q[qi] {
                if firstMatchIndex < 0 { firstMatchIndex = i }
                runLength += 1
                score += 2 + runLength   // contiguous runs score higher than scattered hits
                qi = q.index(after: qi)
            } else {
                runLength = 0
            }
        }
        guard qi == q.endIndex else { return nil }   // not every query char was found, in order
        // Reward an early first hit (matches near the start of the string read as "more relevant").
        score += max(0, 20 - firstMatchIndex)
        return score
    }

    /// Best score across several fields (e.g. a command's title AND its group name), so a
    /// command matches whether the user typed the command or the section it lives under.
    static func bestScore(query: String, fields: [String]) -> Int? {
        fields.compactMap { score(query: query, haystack: $0) }.max()
    }
}
