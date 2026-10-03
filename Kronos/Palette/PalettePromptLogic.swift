// Kronos/Palette/PalettePromptLogic.swift
// Pure rules behind the palette's second step ("Pick date…", "Move to…", "Rename…"): which rows
// a typed phrase produces, and what a rename may write. No SwiftUI, no store; the self-test
// compiles this file standalone against hand-written tables.
import Foundation
import KronosCore

struct PaletteDateRow: Equatable {
    enum Kind: String { case parsed, today, tomorrow, nextWeek, clear }
    let kind: Kind
    /// The day the row sets; nil for `clear`.
    let day: Int?
}

struct PaletteProjectOption: Equatable {
    /// nil is the "No project" row.
    let id: UUID?
    let name: String
}

enum PalettePromptLogic {
    /// Rows for the date step. `names` carries the localized label of each quick row (used only
    /// to match what was typed); `parsed` is a phrase the quick-add grammar understands in the
    /// reader's languages ("fri", "sutra", "za 3 dana", "12.10."). A parsed row is dropped when a
    /// quick row already sets the same day.
    static func dateRows(query: String, today: Int, hasDue: Bool, names: [PaletteDateRow.Kind: String],
                         languages: [String] = QuickAddParser.defaultLanguages,
                         calendar: Calendar = .current) -> [PaletteDateRow] {
        let q = query.trimmingCharacters(in: .whitespaces)
        func listed(_ kind: PaletteDateRow.Kind) -> Bool {
            q.isEmpty || PaletteMatcher.score(query: q, haystack: names[kind] ?? "") != nil
        }
        var quick: [PaletteDateRow] = []
        if listed(.today) { quick.append(PaletteDateRow(kind: .today, day: today)) }
        if listed(.tomorrow) { quick.append(PaletteDateRow(kind: .tomorrow, day: today + 1)) }
        if listed(.nextWeek) { quick.append(PaletteDateRow(kind: .nextWeek, day: today + 7)) }
        var rows = quick
        if !q.isEmpty, let day = parsedDay(q, today: today, languages: languages, calendar: calendar),
           !quick.contains(where: { $0.day == day }) {
            rows.insert(PaletteDateRow(kind: .parsed, day: day), at: 0)
        }
        if hasDue, listed(.clear) { rows.append(PaletteDateRow(kind: .clear, day: nil)) }
        return rows
    }

    /// The day a phrase names when the WHOLE phrase is a date ("buy milk friday" is not one).
    static func parsedDay(_ phrase: String, today: Int, languages: [String], calendar: Calendar) -> Int? {
        let parse = EntryParser.parse(phrase, directory: EntryDirectory(), today: today,
                                      languages: languages, calendar: calendar)
        guard let day = parse.dueDay, parse.title.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return day
    }

    /// Move targets for what was typed, ranked like every other project picker (`ProjectRanking`: match
    /// tier first, recents first for an empty query). The task's current project is not offered; "No
    /// project" comes first on an empty query and is typeable otherwise, only when the task has a project.
    static func projectRows(query: String, projects: [PaletteProjectOption], noneName: String,
                            currentID: UUID?, recents: [UUID: Date] = [:]) -> [PaletteProjectOption] {
        let candidates = projects.compactMap { option in
            option.id.map { ProjectRanking.Candidate(id: $0, name: option.name) }
        }.filter { $0.id != currentID }
        let ranked = ProjectRanking.rank(query: query, projects: candidates, recents: recents)
            .map { PaletteProjectOption(id: $0.id, name: $0.name) }
        guard currentID != nil else { return ranked }
        let none = PaletteProjectOption(id: nil, name: noneName)
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return [none] + ranked }
        return PaletteMatcher.score(query: q, haystack: noneName) != nil ? ranked + [none] : ranked
    }

    /// The title a rename writes, or nil when nothing would change (empty, or the same text).
    static func renamedTitle(current: String, typed: String) -> String? {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t == current ? nil : t
    }
}
