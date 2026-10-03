import Foundation

/// The token the caret is in, as far as the suggestion list is concerned.
public struct EntryActiveToken: Equatable, Sendable {
    public enum Sigil: Sendable { case destination, label, priority, effort, date, template }
    public var sigil: Sigil
    /// The text accepting a suggestion replaces: from the sigil (or the first date word) to
    /// the end of the word the caret is in.
    public var range: Range<Int>
    /// What was typed after the sigil, caret-trimmed ("hit li" for `#hit li|st`).
    public var query: String

    public init(sigil: Sigil, range: Range<Int>, query: String) {
        self.sigil = sigil
        self.range = range
        self.query = query
    }
}

public struct EntrySuggestion: Equatable, Sendable, Identifiable {
    public var id: String
    /// What accepting adds to the pills.
    public var pill: EntryPill
    /// Display name: the project/area/label name, the date phrase. Priority and effort are
    /// named by the UI from `pill` (they are localised there).
    public var title: String
    /// "Create project 'X'" / "Create label 'X'": the thing does not exist yet.
    public var isCreate: Bool
    public var tier: EntryMatchTier?
    /// Text removed when accepted (the typed token); empty for a pill-slot menu.
    public var replaceRange: Range<Int>

    public init(id: String, pill: EntryPill, title: String, isCreate: Bool = false,
                tier: EntryMatchTier? = nil, replaceRange: Range<Int>) {
        self.id = id
        self.pill = pill
        self.title = title
        self.isCreate = isCreate
        self.tier = tier
        self.replaceRange = replaceRange
    }
}

public struct EntrySuggestions: Equatable, Sendable {
    /// nil = the caret is in plain title text: no list.
    public var active: EntryActiveToken?
    public var items: [EntrySuggestion]

    public static let none = EntrySuggestions(active: nil, items: [])
}

/// Suggestion engine: text + caret in, active token and ranked suggestions out. Pure.
public enum EntrySuggester {

    /// Words a `#`/`@` query may span before the caret counts as back in the title.
    static let maxQueryWords = 5

    public static func suggest(text: String, caret: Int, directory: EntryDirectory, today: Int,
                               languages: [String] = QuickAddParser.defaultLanguages,
                               calendar: Calendar = .current, limit: Int = 8) -> EntrySuggestions {
        let units = Array(text.utf16)
        let c = min(max(caret, 0), units.count)
        let lineStart = (units[..<c].lastIndex(of: 10).map { $0 + 1 }) ?? 0
        let lineEnd = units[c...].firstIndex(of: 10) ?? units.count
        func slice(_ r: Range<Int>) -> String { String(decoding: units[r], as: UTF16.self) }

        // `/` template line: the template list owns it (QuickAddTemplates), the engine only says so.
        if lineStart == 0, TemplateQuery.isTemplateInput(slice(0..<lineEnd)) {
            return EntrySuggestions(active: EntryActiveToken(sigil: .template, range: 0..<lineEnd,
                                                             query: TemplateQuery.queryText(slice(0..<lineEnd))), items: [])
        }

        let line = slice(lineStart..<lineEnd)
        let words = EntryMatcher.words(in: line).map {
            EntryWord(text: $0.text, range: ($0.range.lowerBound + lineStart)..<($0.range.upperBound + lineStart))
        }
        // Words that start before the caret; the last of them is "the current word" when the
        // caret is inside it or right after it.
        let before = words.filter { $0.range.lowerBound < c }
        guard let last = before.last else { return .none }
        let inCurrentWord = last.range.upperBound >= c

        // `#` / `@`: the nearest token starter within a few words back, if no other token
        // starter sits between it and the caret.
        for j in stride(from: before.count - 1, through: max(0, before.count - maxQueryWords), by: -1) {
            let w = before[j]
            guard EntryMatcher.startsToken(w.text) else { continue }
            guard let sigil = w.text.first, sigil == "#" || sigil == "@" else { break }
            let queryEnd = max(c, w.range.lowerBound + 1)
            let rawQuery = slice((w.range.lowerBound + 1)..<queryEnd)
            let tokenEnd = last.range.upperBound
            let range = w.range.lowerBound..<tokenEnd
            let items = sigil == "#"
                ? destinationItems(rawQuery: rawQuery, directory: directory, range: range, limit: limit)
                : labelItems(rawQuery: rawQuery, directory: directory, range: range, limit: limit)
            if !items.isEmpty {
                return EntrySuggestions(active: EntryActiveToken(sigil: sigil == "#" ? .destination : .label,
                                                                 range: range, query: rawQuery), items: items)
            }
            break
        }

        guard inCurrentWord else { return .none }

        // `!` priority.
        if last.text.range(of: #"^!{1,4}$"#, options: .regularExpression) != nil {
            let n = last.text.count
            let items = priorityItems(range: last.range, preferring: n)
            return EntrySuggestions(active: EntryActiveToken(sigil: .priority, range: last.range, query: last.text), items: items)
        }

        // `*` / `~` effort. A lone star at the start of a line is a bullet, not a size.
        if let items = effortItems(word: last, isFirstOnLine: words.first == last) {
            return EntrySuggestions(active: EntryActiveToken(sigil: .effort, range: last.range, query: last.text), items: items)
        }

        // Date words: the longest trailing run of plain words that is, or starts, a date phrase.
        for span in [3, 2, 1] where before.count >= span {
            let tail = Array(before.suffix(span))
            guard !tail.contains(where: { EntryMatcher.startsToken($0.text) }) else { continue }
            let range = tail[0].range.lowerBound..<last.range.upperBound
            let typed = tail.enumerated().map { i, w in
                i == tail.count - 1 ? slice(w.range.lowerBound..<min(c, w.range.upperBound)) : w.text
            }
            let items = dateItems(typed: typed, fullWords: tail.map(\.text), range: range, today: today,
                                  languages: languages, calendar: calendar, limit: limit)
            if !items.isEmpty {
                return EntrySuggestions(active: EntryActiveToken(sigil: .date, range: range, query: typed.joined(separator: " ")),
                                        items: items)
            }
        }
        return .none
    }

    // MARK: Pill-slot menus (click a pill to change it)

    /// Suggestions for changing one slot, no text involved. `query` narrows destinations and
    /// labels the same way typing after the sigil does.
    public static func suggestions(for slot: EntryPill.Slot, query: String = "", directory: EntryDirectory,
                                   today: Int, languages: [String] = QuickAddParser.defaultLanguages,
                                   calendar: Calendar = .current, limit: Int = 8) -> [EntrySuggestion] {
        let none = 0..<0
        switch slot {
        case .destination:
            return destinationItems(rawQuery: query, directory: directory, range: none, limit: limit, offerCreate: false)
        case .label:
            return labelItems(rawQuery: query, directory: directory, range: none, limit: limit, offerCreate: false)
        case .priority:
            return priorityItems(range: none, preferring: 0)
        case .effort:
            return effortSizes.map { effortSuggestion($0, range: none) }
        case .due:
            let vocabulary = DatePhrases.buildSystemVocabulary(languages: languages, calendar: calendar)
            return datePhrases(languages: languages).compactMap { phrase -> EntrySuggestion? in
                guard let day = resolve(phrase, today: today, calendar: calendar, vocabulary: vocabulary) else { return nil }
                return EntrySuggestion(id: "due.\(phrase)", pill: .due(day), title: phrase, replaceRange: none)
            }
            .prefix(limit).map { $0 }
        case .repeats:
            // The three plain schedules; a count or a weekday is typed ("every 2 weeks").
            return [RepeatPhrase.Unit.day, .week, .month].map { unit in
                EntrySuggestion(id: "repeat.\(unit.rawValue)", pill: .repeats(RepeatPhrase(unit: unit)),
                                title: "every \(unit.rawValue)", replaceRange: none)
            }
        }
    }

    // MARK: Destinations and labels

    private static func destinationItems(rawQuery: String, directory: EntryDirectory, range: Range<Int>,
                                         limit: Int, offerCreate: Bool = true) -> [EntrySuggestion] {
        let trailingSpace = rawQuery.last?.isWhitespace == true
        let key = EntryMatcher.normalize(rawQuery)
        var hits = rankedDestinations(key: key, directory: directory)
        if !key.isEmpty {
            if trailingSpace {
                // The word is finished: only names that continue it at a word boundary.
                hits = hits.filter { let n = EntryMatcher.normalize($0.name.name); return n == key || n.hasPrefix(key + " ") }
            }
        }
        var items = hits.prefix(limit).map { h in
            EntrySuggestion(id: "dest.\(h.kind).\(h.name.id?.uuidString ?? h.name.name)",
                            pill: .destination(EntryDestination(kind: h.kind, name: h.name.name, id: h.name.id)),
                            title: h.name.name, tier: h.tier, replaceRange: range)
        }
        let hasExact = hits.first.map { $0.tier == .exact } ?? false
        // One word, and not an issue number ("#123" is a reference, not a project to create).
        let isOneWord = !key.isEmpty && !rawQuery.contains(where: \.isWhitespace) && !key.allSatisfy(\.isNumber)
        if offerCreate, isOneWord, !trailingSpace, !hasExact {
            let name = rawQuery.replacingOccurrences(of: "-", with: " ")
            items.append(EntrySuggestion(id: "dest.create.\(name)",
                                         pill: .destination(EntryDestination(kind: .project, name: name, isNew: true)),
                                         title: name, isCreate: true, replaceRange: range))
        }
        return items
    }

    /// Projects in `ProjectRanking`'s order, the one every project picker shows (the inspector's
    /// Project field, the P key, Move to), so `#nova` and a picker typed "nova" list the same
    /// projects in the same order; areas by the matcher. The two are merged by tier, then recent
    /// use, then project before area, so a better match still wins whichever kind it is. An
    /// empty query lists everything, recents first.
    static func rankedDestinations(key: String, directory: EntryDirectory) -> [EntryMatcher.Hit] {
        var byID: [UUID: EntryName] = [:]
        var recents: [UUID: Date] = [:]
        var candidates: [ProjectRanking.Candidate] = []
        for (index, n) in directory.projects.enumerated() where !n.name.isEmpty {
            // A directory built by hand may carry no ids; a stable per-position id stands in.
            let id = n.id ?? UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
            byID[id] = n
            if let used = n.lastUsed { recents[id] = used }
            candidates.append(ProjectRanking.Candidate(id: id, name: n.name))
        }
        var hits: [EntryMatcher.Hit] = []
        for (position, c) in ProjectRanking.rank(query: key, projects: candidates, recents: recents).enumerated() {
            guard let name = byID[c.id] else { continue }
            let tier = key.isEmpty ? EntryMatchTier.exact
                : (EntryMatcher.tier(key: key, candidate: EntryMatcher.normalize(name.name)) ?? .fuzzy)
            hits.append(EntryMatcher.Hit(name: name, kind: .project, tier: tier, order: position))
        }
        let areaHits: [EntryMatcher.Hit]
        if key.isEmpty {
            areaHits = directory.areas.enumerated().filter { !$0.element.name.isEmpty }.map {
                EntryMatcher.Hit(name: $0.element, kind: .area, tier: .exact, order: hits.count + $0.offset)
            }
        } else {
            areaHits = EntryMatcher.rank(key: key, projects: [], areas: directory.areas, maxTier: .fuzzy)
                .map { var h = $0; h.order += hits.count; return h }
        }
        // Two projects keep ProjectRanking's order exactly; the matcher only places areas.
        return (hits + areaHits).sorted { a, b in
            if a.kind == .project, b.kind == .project { return a.order < b.order }
            return EntryMatcher.before(a, b)
        }
    }

    private static func labelItems(rawQuery: String, directory: EntryDirectory, range: Range<Int>,
                                   limit: Int, offerCreate: Bool = true) -> [EntrySuggestion] {
        let trailingSpace = rawQuery.last?.isWhitespace == true
        let key = EntryMatcher.normalize(rawQuery)
        var ranked: [(name: EntryName, tier: EntryMatchTier?, order: Int)] = []
        for (order, n) in directory.labels.enumerated() where !n.name.isEmpty {
            if key.isEmpty { ranked.append((n, nil, order)); continue }
            let cand = EntryMatcher.normalize(n.name)
            guard let t = EntryMatcher.tier(key: key, candidate: cand) else { continue }
            if trailingSpace, !(cand == key || cand.hasPrefix(key + " ")) { continue }
            ranked.append((n, t, order))
        }
        ranked.sort { a, b in
            if a.tier != b.tier { return (a.tier ?? .exact) < (b.tier ?? .exact) }
            switch (a.name.lastUsed, b.name.lastUsed) {
            case let (x?, y?) where x != y: return x > y
            case (.some, .none): return true
            case (.none, .some): return false
            default: return a.order < b.order
            }
        }
        var items = ranked.prefix(limit).map {
            EntrySuggestion(id: "label.\($0.name.name)", pill: .label($0.name.name), title: $0.name.name,
                            tier: $0.tier, replaceRange: range)
        }
        let hasExact = ranked.first.map { $0.tier == .exact } ?? false
        if offerCreate, !key.isEmpty, !rawQuery.contains(where: \.isWhitespace), !key.allSatisfy(\.isNumber), !hasExact {
            let name = rawQuery
            items.append(EntrySuggestion(id: "label.create.\(name)", pill: .label(name), title: name,
                                         isCreate: true, replaceRange: range))
        }
        return items
    }

    // MARK: Priority and effort

    private static func priorityItems(range: Range<Int>, preferring bangs: Int) -> [EntrySuggestion] {
        let levels: [KPriority] = [.low, .medium, .high, .urgent]
        let ordered = levels.filter { $0.rawValue == bangs } + levels.filter { $0.rawValue != bangs }
        return ordered.map { EntrySuggestion(id: "priority.\($0.rawValue)", pill: .priority($0),
                                             title: String(repeating: "!", count: $0.rawValue), replaceRange: range) }
    }

    private static let effortSizes: [KEffort] = [.xs, .s, .m, .l, .xl]

    private static func effortSuggestion(_ e: KEffort, range: Range<Int>) -> EntrySuggestion {
        let label = ["", "xs", "s", "m", "l", "xl"][e.rawValue]
        return EntrySuggestion(id: "effort.\(e.rawValue)", pill: .effort(e), title: "*" + label, replaceRange: range)
    }

    private static func effortItems(word: EntryWord, isFirstOnLine: Bool) -> [EntrySuggestion]? {
        let text = word.text
        guard let f = text.first, f == "*" || f == "~" else { return nil }
        if text.allSatisfy({ $0 == "*" }) {
            guard text.count <= 3 else { return nil }
            if isFirstOnLine { return nil }  // `* item` is a bullet
            let preferred: KEffort = [1: .s, 2: .m, 3: .l][text.count]!
            let sizes = [preferred] + effortSizes.filter { $0 != preferred }
            return sizes.map { effortSuggestion($0, range: word.range) }
        }
        let rest = String(text.dropFirst()).lowercased()
        let sizes = effortSizes.filter { rest.isEmpty || ["", "xs", "s", "m", "l", "xl"][$0.rawValue].hasPrefix(rest) }
        return sizes.isEmpty ? nil : sizes.map { effortSuggestion($0, range: word.range) }
    }

    // MARK: Dates

    private static func datePhrases(languages: [String]) -> [String] {
        let en = ["today", "tomorrow", "day after tomorrow", "this weekend", "weekend", "next week", "next month",
                  "end of week", "end of month",
                  "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
                  "next monday", "next tuesday", "next wednesday", "next thursday", "next friday",
                  "next saturday", "next sunday"]
        let hr = ["danas", "sutra", "prekosutra", "ovaj vikend", "vikend", "sljedeći tjedan", "sljedeći mjesec",
                  "kraj tjedna", "kraj mjeseca",
                  "ponedjeljak", "utorak", "srijeda", "četvrtak", "petak", "subota", "nedjelja"]
        let order = languages.map { String($0.prefix(2)) }
        let hrFirst = (order.firstIndex(of: "hr") ?? Int.max) < (order.firstIndex(of: "en") ?? Int.max)
        return hrFirst ? hr + en : en + hr
    }

    private static func resolve(_ phrase: String, today: Int, calendar: Calendar,
                                vocabulary: DatePhrases.SystemVocabulary) -> Int? {
        let tokens = phrase.split(separator: " ").map(String.init)
        return QuickAddParser.matchDatePhrase(tokens, keep: Array(tokens.indices), today: today,
                                              calendar: calendar, vocabulary: vocabulary)
            .flatMap { $0.consumed.count == tokens.count ? $0.day : nil }
    }

    private static func dateItems(typed: [String], fullWords: [String], range: Range<Int>, today: Int,
                                  languages: [String], calendar: Calendar, limit: Int) -> [EntrySuggestion] {
        let vocabulary = DatePhrases.buildSystemVocabulary(languages: languages, calendar: calendar)
        var items: [EntrySuggestion] = []
        var seen = Set<String>()
        func add(_ phrase: String, _ day: Int) {
            guard seen.insert(phrase).inserted else { return }
            items.append(EntrySuggestion(id: "due.\(phrase)", pill: .due(day), title: phrase, replaceRange: range))
        }


        let key = EntryMatcher.normalize(typed.joined(separator: " "))
        // One bare word needs three letters before it is worth a list ("to" alone is noise).
        guard typed.count > 1 || key.count >= 3 else { return [] }
        var candidates = datePhrases(languages: languages)
        // "in 3" / "za 3": offer the unit completions with the number typed.
        if typed.count >= 2, let n = Int(typed[1]), (1...999).contains(n) {
            switch typed[0].lowercased() {
            case "in": candidates = ["in \(n) day\(n == 1 ? "" : "s")", "in \(n) week\(n == 1 ? "" : "s")", "in \(n) month\(n == 1 ? "" : "s")"]
            case "za": candidates = ["za \(n) dana", "za \(n) tjedna", "za \(n) mjeseca"]
            default: break
            }
        }
        for phrase in candidates where EntryMatcher.normalize(phrase).hasPrefix(key) {
            if let day = resolve(phrase, today: today, calendar: calendar, vocabulary: vocabulary) { add(phrase, day) }
        }
        // Nothing to complete, but the words already are a date the parser reads ("25.9.",
        // "2030-01-15"): offer that exact phrase so it can become a pill.
        if items.isEmpty, let hit = QuickAddParser.matchDatePhrase(fullWords, keep: Array(fullWords.indices), today: today,
                                                                   calendar: calendar, vocabulary: vocabulary),
           hit.consumed.count == fullWords.count {
            add(fullWords.joined(separator: " "), hit.day)
        }
        return Array(items.prefix(limit))
    }
}

/// Text edits the entry field applies when a token becomes a pill or a pill is removed.
public enum EntryEdit {

    /// `text` with `range` cut out and the whitespace around the cut tidied: no double space,
    /// no space left at a line's start or end. Returns the new text and where the caret goes
    /// (UTF-16 offset of the cut).
    public static func removing(_ range: Range<Int>, from text: String) -> (text: String, caret: Int) {
        var units = Array(text.utf16)
        let lo = min(max(range.lowerBound, 0), units.count)
        let hi = min(max(range.upperBound, lo), units.count)
        units.removeSubrange(lo..<hi)
        let space: UInt16 = 32
        let newline: UInt16 = 10
        var caret = lo
        let beforeIsSpace = lo > 0 && units[lo - 1] == space
        let afterIsSpace = lo < units.count && units[lo] == space
        let afterIsBreak = lo >= units.count || units[lo] == newline
        let atLineStart = lo == 0 || units[lo - 1] == newline
        if beforeIsSpace && afterIsSpace {
            units.remove(at: lo)          // "call |mom": the caret stays where the next word starts
        } else if beforeIsSpace && afterIsBreak {
            units.remove(at: lo - 1)
            caret = lo - 1
        } else if atLineStart && afterIsSpace {
            units.remove(at: lo)
        }
        return (String(decoding: units, as: UTF16.self), caret)
    }
}
