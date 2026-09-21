import Foundation

/// The single quick-add grammar used by the global panel, the create modal
/// title field, the inline "+" row and the Due popover (spec/interaction §4).
/// Deterministic, offline, status-blind. One token of each kind is consumed;
/// later tokens of the same kind stay in the title as literal text.
public struct QuickAddParser: Sendable {

    public struct Parsed: Equatable, Sendable {
        /// Remaining title after tokens were consumed, whitespace-collapsed.
        public var title: String
        /// Resolved project name, nil if none matched (quick add never creates).
        public var projectName: String?
        /// Label name; created later by the store if missing.
        public var labelName: String?
        public var priority: KPriority
        public var dueDay: Int?
        /// Unresolved #token that stayed in the title as literal text (§4.2).
        public var unresolvedProjectToken: String?
        /// The `~xs ~s ~m ~l ~xl` effort token, nil when absent.
        /// Optional (not `KEffort.none`) so a caller can tell "the user sized
        /// this XS" from "the user said nothing about size" and leave the
        /// task's existing effort alone in the second case.
        public var effort: KEffort?

        public init(title: String, projectName: String?, labelName: String?,
                    priority: KPriority, dueDay: Int?,
                    unresolvedProjectToken: String? = nil,
                    effort: KEffort? = nil) {
            self.title = title
            self.projectName = projectName
            self.labelName = labelName
            self.priority = priority
            self.dueDay = dueDay
            self.unresolvedProjectToken = unresolvedProjectToken
            self.effort = effort
        }
    }

    public init() {}

    /// - Parameters:
    ///   - input: raw string from the field.
    ///   - projects: non-archived project names available for matching.
    ///   - today: day number for relative date tokens (injectable for tests).
    ///   - languages: BCP-47 language ids whose system (CLDR) relative-date vocabulary is
    ///     consulted, e.g. "de" for a German sample. Default = `Locale.preferredLanguages`
    ///     plus always "en" and "hr", so natural-language dates work regardless of the
    ///     app's display language. Injectable so tests are deterministic and can probe a
    ///     specific language without depending on the host machine's own preferences.
    ///   - calendar: injectable for deterministic weekday/month-end arithmetic in tests.
    public func parse(_ input: String, projects: [String], today: Int,
                       languages: [String] = Self.defaultLanguages,
                       calendar: Calendar = .current) -> Parsed {
        let tokens = input.split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        var keep = Array(tokens.indices)

        var projectName: String?
        var labelName: String?
        var priority: KPriority = .none
        var dueDay: Int?
        var unresolved: String?
        var effort: KEffort?

        func fold(_ s: String) -> String {
            s.replacingOccurrences(of: "đ", with: "d")
             .replacingOccurrences(of: "Đ", with: "D")
             .folding(options: [.caseInsensitive, .diacriticInsensitive],
                      locale: Locale(identifier: "en_US_POSIX"))
        }

        // Priority: standalone 1-4 "!"
        for i in keep where tokens[i].range(of: #"^!{1,4}$"#, options: .regularExpression) != nil {
            priority = [KPriority.low, .medium, .high, .urgent][tokens[i].count - 1]
            keep.removeAll { $0 == i }
            break
        }

        // Effort: standalone *xs/*s/*m/*l/*xl or ~xs/~s/~m/~l/~xl, case-insensitive. `*` is
        // the primary alias, since `~` sits under a dead-key/option chord on a Croatian Mac
        // keyboard while `*` is a plain Shift-8. `~` keeps working for muscle memory and
        // existing docs/tests.
        //
        // Matched against the WHOLE token, never a prefix, so the marker inside a word
        // or a path is not a token: `~/Downloads` keeps its slash and fails the match,
        // `a~b`/`a*b` has no leading marker, and a bare `~`/`*` has no size after it.
        // `5*3 plan` also survives untouched: its first token is "5*3", which does not
        // START with `*` (hasPrefix checks the token's own first character, not any
        // substring), so it is never mistaken for an effort token. A path like
        // `~/Downloads` is common in real task titles, and eating it would silently
        // corrupt the title.
        //
        // Last one wins (the other tokens keep first-wins): a user correcting
        // themselves mid-line types the new size after the old one, and the
        // correction is what they meant.
        let effortSizes: [String: KEffort] = [
            "xs": .xs, "s": .s, "m": .m, "l": .l, "xl": .xl
        ]
        let effortMarkers: [Character] = ["*", "~"]
        // Bare star-count: `*` = small, `**` = medium, `***` = large; 4+ stars is not a token
        // (same "not a token past the max" shape as `!!!!!` for priority). The token must be
        // made ONLY of stars — nothing else — so `5*3` (fails: contains digits), `a*b`/`a*`
        // (fails: contains a letter) and a mixed run never match. This DOES make a lone `*`
        // an effort token (small) where it would otherwise be inert text — a deliberate
        // choice, matched by QuickAddEffortTests.
        let starCountSizes: [Int: KEffort] = [1: .s, 2: .m, 3: .l]
        // One reversed pass over BOTH forms, so "last one wins" is positional (whichever
        // effort-shaped token appears last in the line), not "star-count always beats *s/*m/*l".
        for i in keep.reversed() {
            if tokens[i].allSatisfy({ $0 == "*" }), let e = starCountSizes[tokens[i].count] {
                effort = e
                keep.removeAll { $0 == i }
                break
            }
            if tokens[i].first.map(effortMarkers.contains) == true,
               let e = effortSizes[String(tokens[i].dropFirst()).lowercased()] {
                effort = e
                keep.removeAll { $0 == i }
                break
            }
        }

        // Label: first @token
        for i in keep where tokens[i].hasPrefix("@") && tokens[i].count > 1 {
            labelName = String(tokens[i].dropFirst())
            keep.removeAll { $0 == i }
            break
        }

        // Project: first #token, exact → prefix → substring (§4.2)
        for i in keep where tokens[i].hasPrefix("#") && tokens[i].count > 1 {
            let raw = String(tokens[i].dropFirst())
            let key = fold(raw.replacingOccurrences(of: "-", with: " "))
            let candidates = projects.filter { !$0.isEmpty }
            var matched: String? = nil
            if let exact = candidates.first(where: { fold($0) == key }) {
                matched = exact
            } else if let prefix = candidates.first(where: { fold($0).hasPrefix(key) }) {
                matched = prefix
            } else if let sub = candidates.first(where: { fold($0).contains(key) }) {
                matched = sub
            }
            if let m = matched {
                projectName = m
                keep.removeAll { $0 == i }
            } else {
                unresolved = tokens[i]
            }
            break
        }

        // Date: relative keyword (1-4 words), a weekday name, YYYY-MM-DD, or `25.9.[2026]`.
        // Relative dates span one to four tokens ("next week", "next monday", "in 3 days"), so
        // a single-token lookup can never match them, and a plain today/tomorrow map has no
        // weekday-name or tonight/prekosutra table at all. `matchDatePhrase` below scans 4-,
        // 3-, 2- then 1-token windows starting at each kept position so the longer phrases win
        // over a bare weekday/"next" reading of the same words. The vocabulary itself (hand
        // table + system-sourced CLDR words for `languages` + typo tolerance) lives in
        // DatePhrases.swift; this loop's shape stays constant across vocabulary changes.
        let vocabulary = DatePhrases.buildSystemVocabulary(languages: languages, calendar: calendar)
        if let (dueDayHit, consumed) = Self.matchDatePhrase(tokens, keep: keep, today: today,
                                                              calendar: calendar, vocabulary: vocabulary) {
            dueDay = dueDayHit
            keep.removeAll { consumed.contains($0) }
        }

        // Remaining tokens form the title; the unresolved #token stays in it
        // as literal text (§4.2), which it already does by being kept.
        let kept = tokens.enumerated().filter { keep.contains($0.offset) }.map(\.element)
        let title = kept.joined(separator: " ").trimmingCharacters(in: .whitespaces)

        return Parsed(title: title,
                      projectName: projectName,
                      labelName: labelName,
                      priority: priority,
                      dueDay: dueDay,
                      unresolvedProjectToken: unresolved,
                      effort: effort)
    }
    /// Rewrites the unresolved `#token` in the raw input to a `#`-token for the project the
    /// user actually picked, so re-parsing resolves it: the suggestion chip only carries the
    /// resolved project name, not a rewritten input, so without this the UI shows the pick but
    /// the underlying fields stay unpopulated. Pure: takes the exact literal text
    /// `Parsed.unresolvedProjectToken` held (so the caller does not have to re-derive it) and
    /// the chosen project's real name, and returns the input with the FIRST occurrence of that
    /// literal token replaced. Word-encodes the name the same way a user typing `#acme-skola`
    /// would (spaces -> dashes), which the parser's own `fold` already treats the same as a
    /// space when matching.
    ///
    /// - Returns: `input` unchanged if `unresolvedToken` is empty or not found in it.
    public static func rewriteProjectToken(in input: String, unresolvedToken: String,
                                            resolvedProjectName: String) -> String {
        guard !unresolvedToken.isEmpty, let range = input.range(of: unresolvedToken) else { return input }
        let encoded = "#" + resolvedProjectName.replacingOccurrences(of: " ", with: "-")
        return input.replacingCharacters(in: range, with: encoded)
    }

    /// European short date: `25.9.` (next occurrence on or after today) or `25.9.2026`.
    /// The yearless form needs its trailing dot, so a version number like `1.5` stays in the title.
    static func parseDayMonth(_ token: String, today: Int) -> Int? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let hasYear = parts.count >= 3 && !parts[2].isEmpty
        guard (parts.count == 3 || (parts.count == 4 && parts[3].isEmpty)),
              hasYear || (parts.count == 3 && parts[2].isEmpty),
              let d = Int(parts[0]), let m = Int(parts[1]), (1...31).contains(d), (1...12).contains(m),
              parts[0].count <= 2, parts[1].count <= 2 else { return nil }
        let cal = Calendar.current
        func day(_ year: Int) -> Int? {
            var c = DateComponents(); c.year = year; c.month = m; c.day = d
            guard let date = cal.date(from: c), cal.component(.day, from: date) == d else { return nil }
            return Day.from(date, calendar: cal)
        }
        if hasYear {
            guard let y = Int(parts[2]), parts[2].count == 4 else { return nil }
            return day(y)
        }
        let thisYear = cal.component(.year, from: Day.date(today, calendar: cal))
        guard let candidate = day(thisYear) else { return nil }
        return candidate >= today ? candidate : day(thisYear + 1)
    }

    /// Weekday name -> ISO weekday number (1 = Monday … 7 = Sunday), same numbering
    /// `RecurrenceRule`'s own weekday table uses. English and Croatian, full and abbreviated,
    /// regardless of the app's display language.
    ///
    /// The bare 3-letter Croatian abbreviations ("pet", "sub", "sri", "ned", "pon", "uto",
    /// "cet"/"čet") are intentionally left OUT of this table — "Kupiti pet jabuka" ("buy five
    /// apples") would otherwise silently become a Friday task, since "pet" also abbreviates
    /// "petak". Those letters are real words too common to treat as a date by default. They
    /// still resolve when a swallowed preposition directly precedes them ("do pet" is not
    /// idiomatic Croatian, so this in practice means the FULL names after a preposition, e.g.
    /// "do petka" via the inflected form in `DatePhrases`) — see
    /// `DatePhrases.ambiguousBareAbbreviations`, which this table intentionally leaves the
    /// short forms out of and that enum enforces the drop.
    static let weekdayNames: [String: Int] = [
        "monday": 1, "mon": 1, "ponedjeljak": 1,
        "tuesday": 2, "tue": 2, "utorak": 2,
        "wednesday": 3, "wed": 3, "srijeda": 3,
        "thursday": 4, "thu": 4, "četvrtak": 4, "cetvrtak": 4,
        "friday": 5, "fri": 5, "petak": 5,
        "saturday": 6, "sat": 6, "subota": 6,
        "sunday": 7, "sun": 7, "nedjelja": 7,
    ]

    /// Languages whose CLDR relative-date vocabulary is consulted by default: the system's
    /// own preferred languages plus always English and Croatian, so relative dates keep
    /// working regardless of the system's language setting.
    public static let defaultLanguages: [String] = {
        var langs = Locale.preferredLanguages.map { String($0.prefix(2)) }
        if !langs.contains("en") { langs.append("en") }
        if !langs.contains("hr") { langs.append("hr") }
        return langs
    }()

    /// `today`'s own weekday number, 1 = Monday … 7 = Sunday (Calendar's `.weekday` is
    /// 1 = Sunday-based regardless of `firstWeekday`, so it is remapped here rather than
    /// depending on a calendar's `firstWeekday` setting, which the app's `KronosLocale.calendar`
    /// sets but this app-agnostic Core file has no access to).
    private static func isoWeekday(_ day: Int, calendar: Calendar) -> Int {
        let sunday1 = calendar.component(.weekday, from: Day.date(day, calendar: calendar))
        return sunday1 == 1 ? 7 : sunday1 - 1
    }

    /// The next occurrence of `target` weekday strictly AFTER `today` (never today itself —
    /// "next monday" typed on a Monday means the one in 7 days, not "now").
    private static func nextWeekday(_ target: Int, after today: Int, calendar: Calendar) -> Int {
        let current = isoWeekday(today, calendar: calendar)
        let delta = ((target - current + 7 - 1) % 7) + 1
        return today + delta
    }

    /// Scans 4-, 3-, 2- then 1-token windows starting at each still-live position in `keep`
    /// (longer phrases first, so "next week" is not read as a bare "next" plus a stray
    /// "week", and "next monday" is not read as the weekday table matching "monday" alone
    /// while "next" leaks into the title). The 4-token span exists for a swallowed
    /// preposition in front of a 3-token phrase ("do za tjedan dana" is not real Croatian,
    /// but "za tjedan dana" itself is 3 tokens and a leading "do"/"by" before a 1-3 token
    /// phrase needs the extra slot). Returns the matched day and the exact token indices it
    /// consumed, or nil.
    static func matchDatePhrase(_ tokens: [String], keep: [Int], today: Int,
                                 calendar: Calendar, vocabulary: DatePhrases.SystemVocabulary
    ) -> (day: Int, consumed: [Int])? {
        let sortedKeep = keep.sorted()
        for startPos in sortedKeep.indices {
            for span in [4, 3, 2, 1] {
                guard startPos + span <= sortedKeep.count else { continue }
                let window = Array(sortedKeep[startPos..<(startPos + span)])
                // The window must be CONSECUTIVE token indices (no already-consumed token, e.g.
                // an eaten #project, sitting between the words of a phrase).
                guard window == Array(window[0]...window[0] + span - 1) else { continue }
                let words = window.map { tokens[$0].lowercased() }
                // A bare English 3-letter weekday abbreviation ("mon", "fri", "sun", …)
                // collides with ordinary words ("Buy sun cream" -> Sunday, "Wed the two
                // configs" -> Wednesday) when read anywhere in the title. It counts as a date
                // only at the LAST live token, or directly after a swallowed preposition /
                // "next" / "this" — both are positional facts only this window scan can see,
                // so the gate lives here rather than in `dayFor`.
                if span == 1, DatePhrases.isEnglishAmbiguousWeekdayAbbreviation(words[0]) {
                    let isLastToken = window[0] == sortedKeep.last
                    let precedingRawIndex = window[0] - 1
                    let isGuarded = precedingRawIndex >= 0
                        && DatePhrases.isEnglishWeekdayContextGuard(tokens[precedingRawIndex].lowercased())
                    guard isLastToken || isGuarded else { continue }
                }
                if let day = dayFor(phrase: words, today: today, calendar: calendar, vocabulary: vocabulary) {
                    return (day, window)
                }
            }
        }
        return nil
    }

    private static func dayFor(phrase words: [String], today: Int, calendar: Calendar,
                                vocabulary: DatePhrases.SystemVocabulary) -> Int? {
        if let day = dayForDirect(phrase: words, today: today, calendar: calendar, vocabulary: vocabulary) {
            return day
        }
        // A leading swallowed preposition ("by friday", "do petka") — tried only after the
        // direct reading fails, so "za" heading its OWN "za N dana" grammar (case 3 below)
        // is never misread as the preposition in front of a shorter phrase: resolve the
        // REST of the window and, if it matches, consume the preposition too (the caller
        // already returns the whole `window`, so this just needs to succeed).
        if words.count > 1, DatePhrases.isSwallowedPreposition(words[0]) {
            return dayForDirect(phrase: Array(words.dropFirst()), today: today, calendar: calendar, vocabulary: vocabulary)
        }
        return nil
    }

    private static func dayForDirect(phrase words: [String], today: Int, calendar: Calendar,
                                      vocabulary: DatePhrases.SystemVocabulary) -> Int? {
        switch words.count {
        case 3:
            // "day after tomorrow" (English hand phrase; Croatian's own is the single word
            // "prekosutra", already in the hand table's 1-word path).
            if words == ["day", "after", "tomorrow"] { return today + 2 }
            // "end of week" / "end of month" (English 3-token hand phrases).
            if let rule = DatePhrases.resolveThreeWord(words[0], words[1], words[2]) {
                return resolve(rule, today: today, calendar: calendar)
            }
            // "in 3 days" / "za 3 dana" / "in five days" / "za pet dana" — the number word
            // path resolves through DatePhrases.resolveNumberWord so "pet" here means FIVE,
            // never Friday (the ambiguous-abbreviation drop only applies to a BARE token).
            guard words[0] == "in" || words[0] == "za" else { return nil }
            // "za tjedan dana" / "za mjesec dana": Croatian idiom "<unit> of days" for "in a
            // <unit>" — the middle word IS the real unit (week/month), the trailing "dana"
            // is filler, not a second unit. Checked before the generic number+unit reading.
            if DatePhrases.isWeekUnit(words[1]), DatePhrases.isDayUnit(words[2]) { return today + 7 }
            if DatePhrases.isMonthUnit(words[1]), DatePhrases.isDayUnit(words[2]) { return addMonths(1, to: today, calendar: calendar) }
            // "in a week" / "in a month": English indefinite article as N = 1.
            let n = Int(words[1]) ?? DatePhrases.resolveNumberWord(words[1]) ?? (words[1] == "a" ? 1 : nil)
            guard let n else { return nil }
            if DatePhrases.isDayUnit(words[2]) { return today + n }
            if DatePhrases.isWeekUnit(words[2]) { return today + n * 7 }
            if DatePhrases.isMonthUnit(words[2]) { return addMonths(n, to: today, calendar: calendar) }
            return nil
        case 2:
            if words[0] == "next" || words[0] == "sljedeći" || words[0] == "sljedeci" {
                if words[1] == "week" || DatePhrases.isWeekWord(words[1]) { return today + 7 }
                if let weekday = weekdayNames[words[1]] {
                    return nextWeekday(weekday, after: today, calendar: calendar)
                }
            }
            if DatePhrases.isNextWeekWord(words[0]), DatePhrases.isWeekWord(words[1]) {
                return today + 7
            }
            if let rule = DatePhrases.resolveTwoWord(words[0], words[1]) {
                return resolve(rule, today: today, calendar: calendar)
            }
            return nil
        case 1:
            let word = words[0]
            if let weekday = weekdayNames[word] {
                return nextWeekday(weekday, after: today, calendar: calendar)
            }
            if let rule = DatePhrases.resolveWord(word, vocabulary: vocabulary) {
                return resolve(rule, today: today, calendar: calendar)
            }
            return Day.parseISO(word) ?? parseDayMonth(word, today: today)
        default:
            return nil
        }
    }

    /// Turns a `DatePhrases.WordRule` into a concrete day number.
    private static func resolve(_ rule: DatePhrases.WordRule, today: Int, calendar: Calendar) -> Int? {
        switch rule {
        case .offset(let n): return today + n
        case .weekday(let target): return nextWeekday(target, after: today, calendar: calendar)
        case .number: return nil // only meaningful inside the 3-token "in|za N unit" window
        case .endOfWeek: return nextWeekday(5, after: today - 1, calendar: calendar) // Friday, today counts
        case .endOfMonth: return endOfMonth(today, calendar: calendar)
        case .nextMonth: return addMonths(1, to: today, calendar: calendar)
        case .nextYear: return addMonths(12, to: today, calendar: calendar)
        case .weekendStart: return nextWeekday(6, after: today - 1, calendar: calendar) // Saturday, today counts
        }
    }

    /// Last day of `today`'s own month.
    private static func endOfMonth(_ today: Int, calendar: Calendar) -> Int {
        let date = Day.date(today, calendar: calendar)
        let range = calendar.range(of: .day, in: .month, for: date) ?? 1..<2
        var comps = calendar.dateComponents([.year, .month], from: date)
        comps.day = range.upperBound - 1
        let last = calendar.date(from: comps) ?? date
        return Day.from(last, calendar: calendar)
    }

    /// Same day-of-month `n` months from `today`, clamped to the target month's last day
    /// (Jan 31 + 1 month -> Feb 28/29, never "Mar 3").
    private static func addMonths(_ n: Int, to today: Int, calendar: Calendar) -> Int {
        let date = Day.date(today, calendar: calendar)
        guard let advanced = calendar.date(byAdding: .month, value: n, to: date) else { return today }
        return Day.from(advanced, calendar: calendar)
    }
}