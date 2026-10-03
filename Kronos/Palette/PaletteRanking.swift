// Kronos/Palette/PaletteRanking.swift
// Pure ranking rules for the command palette: which tasks make the cut, and which group leads.
// Foundation + KronosCore text folding only, so scripts/palette-selftest.swift can compile it
// standalone together with PaletteMatcher.swift and check it against hand-written tables.
import Foundation
import KronosCore

/// What the ranker needs to know about one task: an opaque key, its title and its notes.
struct PaletteTaskCandidate: Equatable {
    let key: String
    let title: String
    let notes: String
    /// The notes already folded and cut (see `PaletteTaskRanking.foldedNotes`), for callers that
    /// cache them: folding thousands of notes on every keystroke is the slow part. Nil = fold here.
    var foldedNotes: String? = nil
}

/// One ranked task. `inTitle` is false when only the notes matched.
struct PaletteTaskHit: Equatable {
    let key: String
    let score: Int
    let inTitle: Bool
}

enum PaletteTaskRanking {
    /// Task rows shown at most (spec: "up to 8 task titles").
    static let limit = 8
    /// Notes are folded and scanned only up to this many characters, so a task with a very
    /// long note cannot slow every keystroke.
    static let notesScanLimit = 2000

    /// Every candidate is scored first; only then are the best `limit` kept. Title hits come
    /// before notes-only hits whatever their scores; ties keep the candidates' own order.
    static func top(query: String, candidates: [PaletteTaskCandidate], limit: Int = limit) -> [PaletteTaskHit] {
        var hits: [(hit: PaletteTaskHit, order: Int)] = []
        let notesQuery = KTextFold.fold(query).trimmingCharacters(in: .whitespaces)
        for (order, c) in candidates.enumerated() {
            if let s = PaletteMatcher.score(query: query, haystack: c.title) {
                hits.append((PaletteTaskHit(key: c.key, score: s, inTitle: true), order))
            } else if let s = notesScore(foldedQuery: notesQuery, foldedNotes: c.foldedNotes ?? foldedNotes(c.notes)) {
                hits.append((PaletteTaskHit(key: c.key, score: s, inTitle: false), order))
            }
        }
        hits.sort { a, b in
            if a.hit.inTitle != b.hit.inTitle { return a.hit.inTitle }
            if a.hit.score != b.hit.score { return a.hit.score > b.hit.score }
            return a.order < b.order
        }
        return hits.prefix(limit).map(\.hit)
    }

    /// Notes match as a plain substring (a fuzzy subsequence over a paragraph matches almost
    /// anything). Earlier in the note scores higher.
    static func notesScore(query: String, notes: String) -> Int? {
        notesScore(foldedQuery: KTextFold.fold(query).trimmingCharacters(in: .whitespaces), foldedNotes: foldedNotes(notes))
    }

    /// The text the notes match against: cut to `notesScanLimit` characters, then folded.
    static func foldedNotes(_ notes: String) -> String {
        notes.isEmpty ? "" : KTextFold.fold(String(notes.prefix(notesScanLimit)))
    }

    static func notesScore(foldedQuery q: String, foldedNotes h: String) -> Int? {
        guard q.count >= 2, !h.isEmpty, let r = h.range(of: q) else { return nil }
        return max(1, 500 - h.distance(from: h.startIndex, to: r.lowerBound))
    }
}

enum PaletteGroupOrder {
    /// True when the Tasks group should lead the list: the best task TITLE hit scores strictly
    /// higher than the best command hit. A notes-only hit never moves the group.
    static func tasksFirst(bestTaskTitleScore: Int?, bestCommandScore: Int?) -> Bool {
        guard let task = bestTaskTitleScore else { return false }
        guard let command = bestCommandScore else { return true }
        return task > command
    }
}
