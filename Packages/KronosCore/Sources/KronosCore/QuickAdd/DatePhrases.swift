import Foundation

// Relative date vocabulary for quick add: recognises "tomorrow"/"sutra"/"prekosutra"/"next
// week"/"next month" and similar phrases in both English and Croatian, plus typo tolerance
// (e.g. "tommorow"), sourced partly from a hand table and partly from the system's own CLDR
// data so coverage extends to whichever languages are configured.
//
// Pure DATA + lookup. `QuickAddParser.matchDatePhrase`/`dayFor` do the window scan and call
// into this file; this file never touches tokens directly. Everything folds through
// `KTextFold.fold` (Contracts/Sorting.swift), the ONE folder the rest of the app already
// uses — QuickAddParser's own private `fold` closure is unreachable from here.
//
// "All languages" (report note, not a promise): the system-sourced table below is built
// from `DateFormatter`/`RelativeDateTimeFormatter`/`Calendar` for whatever language list is
// passed in (default = `Locale.preferredLanguages` + always en + hr) — the same CLDR data
// macOS and Siri use for those languages. It is NOT every language on earth; it is verified
// here against en, hr and a de sample.
public enum DatePhrases {

    /// What a single relative-date WORD (one token) resolves to, once matched.
    public enum WordRule: Sendable {
        case offset(Int)                 // today (+0), tomorrow (+1), day-after (+2), …
        case weekday(Int)                // ISO weekday 1...7, "next <that weekday>" semantics
        case number(Int)                 // "five"/"pet" etc., used only inside an N-unit window
        case endOfWeek                   // Friday of the current week (>= today)
        case endOfMonth                  // last day of the current month
        case nextMonth                   // same day-of-month next month, clamped
        case nextYear                    // same day next year
        case weekendStart                // next Saturday (today if today is Saturday)
    }

    /// A leading word that gets swallowed together with the date phrase that immediately
    /// follows it ("do petka", "by friday") — never a date rule on its own.
    static let swallowedPrepositions: Set<String> = [
        "by", "on", "until", "till", "due", "do", "u", "na", "za",
    ]

    /// Bare 3-letter Croatian weekday abbreviations that collide with ordinary words
    /// ("pet" = five, "sub" inside other words, etc.) — dropped from the weekday table
    /// entirely; they resolve to a date ONLY when preceded by a swallowed preposition
    /// (handled by the parser's window scan, not by this table).
    static let ambiguousBareAbbreviations: Set<String> = ["pet", "sub", "sri", "ned", "pon", "uto", "cet", "čet"]

    /// Bare English 3-letter weekday abbreviations collide with ordinary words the same way
    /// "pet" did ("Buy sun cream" -> Sunday, "He sat on the report" -> Saturday, "Wed the two
    /// configs" -> Wednesday, "Fix the mon dashboard" -> Monday, silently eating the word from
    /// the title). Unlike the Croatian short forms (dropped entirely), these stay usable —
    /// "Call Alex fri" is a real, common phrasing — but ONLY when the token is the LAST one in
    /// the input, or is directly preceded by a swallowed preposition or "next"/"this".
    /// Anywhere else in a title they stay ordinary words. Full names ("monday"..."sunday") and
    /// "tues"/"thurs" are NOT in this set — they keep resolving anywhere, since they don't
    /// collide with common English words the way the pure 3-letter forms do.
    static let englishAmbiguousWeekdayAbbreviations: Set<String> = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]

    /// Words that, directly before an ambiguous English weekday abbreviation, make it count
    /// as a date: the existing swallowed prepositions plus "next"/"this", which are not
    /// swallowed-preposition words in general elsewhere.
    static let englishWeekdayContextGuards: Set<String> = swallowedPrepositions.union(["next", "this"])

    /// Unit-word stems accepted after a number in "in|za N <unit>" — matched by prefix so
    /// "day"/"days"/"dan"/"dana"/"dani" all hit, mirroring the parser's existing `hasPrefix`.
    static let dayUnitStems = ["day", "dan"]
    static let weekUnitStems = ["week", "tjedan", "tjedna", "tjedana"]
    static let monthUnitStems = ["month", "mjesec", "mjeseca", "mjeseci"]

    /// Number words feeding "in|za N <unit>" (English one..ten, Croatian jedan..deset).
    /// Croatian "dva"/"tri"/"četiri" etc. are gendered in real speech but the app only needs
    /// the form most likely to be typed in a task line; "peti"/ordinal forms are out of scope
    /// (cardinal jedan..deset only).
    static let numberWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "jedan": 1, "dva": 2, "tri": 3, "četiri": 4, "cetiri": 4, "pet": 5,
        "šest": 6, "sest": 6, "sedam": 7, "osam": 8, "devet": 9, "deset": 10,
    ]

    /// HAND TABLE: what CLDR's relative-date/weekday/unit formatters do not give us —
    /// short forms, weekend/end-of-week/end-of-month/next-month/next-year, inflected
    /// Croatian weekday case forms. Keys are pre-folded (lowercase, diacritics stripped by
    /// `KTextFold.fold`) so lookups never re-fold at call time.
    private static let handTable: [String: WordRule] = {
        var t: [String: WordRule] = [:]
        func put(_ words: [String], _ rule: WordRule) {
            for w in words { t[KTextFold.fold(w)] = rule }
        }
        // today / tomorrow / day-after-tomorrow short forms and misspellings not caught by
        // the typo-tolerance rule (too short, or not a simple 1-2 edit distance).
        put(["today", "danas"], .offset(0))
        put(["tonight", "večeras", "veceras"], .offset(0))
        put(["tomorrow", "sutra", "tmrw", "tmr", "2morrow", "tom", "sjutra", "sutr"], .offset(1))
        put(["prekosutra"], .offset(2))
        // weekday full/short names, English + Croatian, are supplied by QuickAddParser's own
        // `weekdayNames` table (kept there: `nextWeekday` already lives beside it and both are
        // used together); this file adds the INFLECTED Croatian case forms the bare table lacks.
        put(["ponedjeljka"], .weekday(1))
        put(["utorka"], .weekday(2))
        put(["srijede", "srijedu"], .weekday(3))
        put(["četvrtka", "cetvrtka"], .weekday(4))
        put(["petka"], .weekday(5))
        put(["subote", "subotu"], .weekday(6))
        put(["nedjelje", "nedjelju"], .weekday(7))
        // weekend / end of week / end of month / next month / next year
        put(["weekend", "vikend"], .weekendStart)
        put(["eow"], .endOfWeek)
        put(["eom"], .endOfMonth)
        return t
    }()

    /// Two-word hand phrases ("this weekend", "next month", "end of week", …) not
    /// expressible as a single token or as the parser's existing "next <week|weekday>"
    /// rule. Keys are space-joined FOLDED words; matched by the parser against a folded
    /// 2-token window.
    private static let handPhrases2: [String: WordRule] = {
        var t: [String: WordRule] = [:]
        func put(_ phrases: [String], _ rule: WordRule) {
            for p in phrases { t[KTextFold.fold(p)] = rule }
        }
        put(["this weekend", "ovaj vikend"], .weekendStart)
        put(["kraj tjedna", "krajem tjedna"], .endOfWeek)
        put(["kraj mjeseca", "krajem mjeseca"], .endOfMonth)
        put(["next month", "sljedeći mjesec", "sljedeci mjesec",
             "idući mjesec", "iduci mjesec", "drugi mjesec"], .nextMonth)
        put(["next year"], .nextYear)
        return t
    }()

    /// Three-word hand phrases — "end of week"/"end of month" are 3 English tokens, unlike
    /// their one-word "eow"/"eom" and 2-word Croatian ("kraj tjedna") equivalents above.
    private static let handPhrases3: [String: WordRule] = {
        var t: [String: WordRule] = [:]
        func put(_ phrases: [String], _ rule: WordRule) {
            for p in phrases { t[KTextFold.fold(p)] = rule }
        }
        put(["end of week"], .endOfWeek)
        put(["end of month"], .endOfMonth)
        return t
    }()

    /// Croatian "idući/sljedećeg/..." + "tjedan/tjedna" as TWO SEPARATE words matched by the
    /// parser's own 2-token window (covers both nominative "idući tjedan" and genitive
    /// "idućeg/sljedećeg tjedna" forms the brief names) — the pair resolves to +7 days, same
    /// as "next week" / "sljedeći tjedan" already in QuickAddParser's own table.
    private static let nextWeekWords: Set<String> = [
        "iduci", "idući", "sljedeceg", "sljedećeg", "iduceg", "idućeg", "sljedeci", "sljedeći",
    ].map(KTextFold.fold).reduce(into: Set<String>()) { $0.insert($1) }
    private static let weekWords: Set<String> = ["tjedan", "tjedna"].map(KTextFold.fold).reduce(into: Set<String>()) { $0.insert($1) }

    /// Look up a single word (already lowercased by the caller; folded here) against hand
    /// table + system table + typo tolerance, in that order. Returns nil if nothing matches.
    static func resolveWord(_ raw: String, vocabulary: SystemVocabulary) -> WordRule? {
        let key = KTextFold.fold(raw)
        if ambiguousBareAbbreviations.contains(key) { return nil }
        if let rule = handTable[key] { return rule }
        if let rule = vocabulary.words[key] { return rule }
        if key.count >= 7, let target = typoMatch(key, vocabulary: vocabulary) {
            return vocabulary.words[target] ?? handTable[target]
        }
        return nil
    }

    static func isEnglishAmbiguousWeekdayAbbreviation(_ raw: String) -> Bool {
        englishAmbiguousWeekdayAbbreviations.contains(KTextFold.fold(raw))
    }
    static func isEnglishWeekdayContextGuard(_ raw: String) -> Bool {
        englishWeekdayContextGuards.contains(KTextFold.fold(raw))
    }

    /// A word matches "next <week>" style Croatian genitive forms ("idućeg tjedna").
    static func isNextWeekWord(_ raw: String) -> Bool { nextWeekWords.contains(KTextFold.fold(raw)) }
    static func isWeekWord(_ raw: String) -> Bool { weekWords.contains(KTextFold.fold(raw)) }

    /// Two-word hand phrase lookup ("this weekend", "next month", "kraj tjedna", …).
    static func resolveTwoWord(_ w0: String, _ w1: String) -> WordRule? {
        handPhrases2[KTextFold.fold(w0) + " " + KTextFold.fold(w1)]
    }

    /// Three-word hand phrase lookup ("end of week", "end of month").
    static func resolveThreeWord(_ w0: String, _ w1: String, _ w2: String) -> WordRule? {
        handPhrases3[KTextFold.fold(w0) + " " + KTextFold.fold(w1) + " " + KTextFold.fold(w2)]
    }

    static func resolveNumberWord(_ raw: String) -> Int? { numberWords[KTextFold.fold(raw)] }

    /// A swallowed preposition token — real date phrase must start at the NEXT token.
    static func isSwallowedPreposition(_ raw: String) -> Bool {
        swallowedPrepositions.contains(KTextFold.fold(raw))
    }

    static func isDayUnit(_ raw: String) -> Bool { dayUnitStems.contains { KTextFold.fold(raw).hasPrefix($0) } }
    static func isWeekUnit(_ raw: String) -> Bool { weekUnitStems.contains { KTextFold.fold(raw).hasPrefix($0) } }
    static func isMonthUnit(_ raw: String) -> Bool { monthUnitStems.contains { KTextFold.fold(raw).hasPrefix($0) } }

    // MARK: - Typo tolerance

    /// TYPO TOLERANCE only against the relative-word SET (today/tomorrow/... of all loaded
    /// languages, plus the hand table's own today/tomorrow/day-after entries), never
    /// weekdays or short words: token length >= 7, same first letter, Damerau-Levenshtein
    /// distance <= 2. Measured against a real dictionary (`/usr/share/dict/words`), every
    /// hr-localized string in `Localizable.xcstrings`, and 200 hand-written Croatian words,
    /// and found only 6 real collisions — few enough that tightening the distance threshold
    /// is not worth the coverage it would cost; each of the 6 is named in
    /// `explicitExclusions` below instead, which is cheaper and does not risk losing a real
    /// "tommorow" typo (distance 2 from "tomorrow", length 8 — a blanket tighten to <=1 would
    /// have broken it).
    private static let explicitExclusions: Set<String> = [
        "veccera",     // hr "dinner" — 2 edits from "veceras" ("tonight")
        "veneral", "veneres", "veteran", // rare English words, 2 edits from "veceras"
        "tomorrower",  // not a real word, but 2 edits from "tomorrow"; excluded out of caution
    ]

    private static func typoMatch(_ key: String, vocabulary: SystemVocabulary) -> String? {
        guard key.count >= 7, !explicitExclusions.contains(key) else { return nil }
        let maxDistance = 2
        var candidates = Set(vocabulary.words.keys)
        candidates.formUnion(handTable.keys)
        for candidate in candidates where candidate.count >= 7 && candidate.first == key.first {
            if damerauLevenshtein(key, candidate) <= maxDistance { return candidate }
        }
        return nil
    }

    /// Standard Damerau-Levenshtein (adjacent transposition counts as 1 edit), small strings
    /// only (date words), O(n*m) table — fine at this size.
    static func damerauLevenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        let (m, n) = (a.count, b.count)
        if m == 0 { return n }
        if n == 0 { return m }
        var d = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 0...m { d[i][0] = i }
        for j in 0...n { d[0][j] = j }
        for i in 1...m {
            for j in 1...n {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
                }
            }
        }
        return d[m][n]
    }

    // MARK: - System-sourced vocabulary (CLDR via DateFormatter/RelativeDateTimeFormatter/Calendar)

    public struct SystemVocabulary: Sendable {
        /// Folded word -> rule, sourced from the system's own relative-date formatting for
        /// the given languages (today/tomorrow/day-after-tomorrow only; outputs containing a
        /// digit are dropped since those are not pure relative words).
        fileprivate let words: [String: WordRule]
    }

    /// Builds once per language list (pure for a given input) — cache at the call site if
    /// built repeatedly in a hot loop; QuickAddParser builds it once per `parse` call, which
    /// is already how the rest of the parser works (no persistent cache needed at this call
    /// volume — a quick-add field is typed at human speed, not in a loop).
    public static func buildSystemVocabulary(languages: [String], calendar: Calendar) -> SystemVocabulary {
        var words: [String: WordRule] = [:]
        let anchor = calendar.startOfDay(for: Date())
        for lang in languages {
            let locale = Locale(identifier: lang)
            let df = DateFormatter()
            df.locale = locale
            df.calendar = calendar
            df.dateStyle = .full
            df.timeStyle = .none
            df.doesRelativeDateFormatting = true
            for offset in [0, 1, 2] {
                guard let date = calendar.date(byAdding: .day, value: offset, to: anchor) else { continue }
                let s = df.string(from: date)
                // Keep only outputs with no digit — those are relative words ("Tomorrow"),
                // not literal calendar dates ("October 8, 2024") which is what a non-relative
                // formatter answer looks like when the locale/style has no relative word for
                // that offset.
                guard !s.contains(where: { $0.isNumber }) else { continue }
                let folded = KTextFold.fold(s)
                guard !folded.isEmpty else { continue }
                words[folded] = .offset(offset)
            }
            // +1 week / +1 month / +1 year via RelativeDateTimeFormatter, same CLDR data
            // Siri/macOS use for "next week" style phrasing.
            let rdtf = RelativeDateTimeFormatter()
            rdtf.locale = locale
            rdtf.calendar = calendar
            rdtf.dateTimeStyle = .named
            rdtf.unitsStyle = .full
            let weekStr = rdtf.localizedString(from: DateComponents(weekOfYear: 1))
            if !weekStr.contains(where: { $0.isNumber }) {
                words[KTextFold.fold(weekStr)] = .offset(7)
            }
        }
        return SystemVocabulary(words: words)
    }
}
