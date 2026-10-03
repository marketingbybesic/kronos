import Foundation

/// Grammar v2: the same tokens as `QuickAddParser` (`!` priority, `*`/`~` effort, `@label`,
/// `#destination`, date words) but every consumed token carries its range, a `#` token
/// resolves against projects AND areas, and a name may span several words ("#hit list call
/// mom" files into "Hit list" and leaves "call mom"). Pure and deterministic.
///
/// Rules, in the order they run (so a later rule never sees words an earlier one took):
///  1. priority: the first standalone `!`..`!!!!`.
///  2. effort: the LAST `*`/`**`/`***` or `*xs`..`*xl` (`~` works like `*`).
///  3. label: the first `@word`. An existing label whose name has several words wins when
///     the words after the `@` spell it ("@deep work call mom"); otherwise the one word.
///  4. destination: the first `#word` (later `#` tokens stay in the title). Greedy over the
///     words that follow it: exact match (longest first), then prefix (longest first), then,
///     for one word only, word-prefix and contains. Ties by recent use, then project before
///     area, then list order. A multi-word match needs the whole name or a prefix of it, so a
///     stray title word is never swallowed by a loose substring match.
///  5. repeat (only with `readsRepeat`): the first "every week" / "svaki tjedan" phrase
///     (RepeatPhrase.swift). It runs before the date so "every monday" is a schedule, not a
///     one-off Monday.
///  6. date: the first date phrase of one to four words among what is left.
public enum EntryParser {

    /// The most words one `#` name may span. Longer names still match by prefix of their
    /// first words; this only bounds the search.
    static let maxNameWords = 6

    /// - Parameter readsRepeat: true only for surfaces that can store a repeat (the entry field
    ///   and `QuickAddCreate`). Everywhere else "every week" stays in the title as typed, so a
    ///   caller that cannot keep the schedule never silently drops those words.
    public static func parse(_ line: String, directory: EntryDirectory, today: Int,
                             languages: [String] = QuickAddParser.defaultLanguages,
                             calendar: Calendar = .current, readsRepeat: Bool = false) -> EntryParse {
        let words = EntryMatcher.words(in: line)
        var consumed = Set<Int>()
        var tokens: [EntryToken] = []
        var unresolved: EntryUnresolved?

        func live() -> [Int] { words.indices.filter { !consumed.contains($0) } }
        func take(_ indices: ClosedRange<Int>, _ pill: EntryPill) {
            for i in indices { consumed.insert(i) }
            tokens.append(EntryToken(range: words[indices.lowerBound].range.lowerBound..<words[indices.upperBound].range.upperBound,
                                     pill: pill))
        }

        // 1. Priority.
        for i in live() where words[i].text.range(of: #"^!{1,4}$"#, options: .regularExpression) != nil {
            take(i...i, .priority([KPriority.low, .medium, .high, .urgent][words[i].text.count - 1]))
            break
        }

        // 2. Effort, last one wins, positionally across both spellings.
        let sizes: [String: KEffort] = ["xs": .xs, "s": .s, "m": .m, "l": .l, "xl": .xl]
        let starSizes: [Int: KEffort] = [1: .s, 2: .m, 3: .l]
        for i in live().reversed() {
            let w = words[i].text
            if w.allSatisfy({ $0 == "*" }), let e = starSizes[w.count] { take(i...i, .effort(e)); break }
            if let f = w.first, f == "*" || f == "~", let e = sizes[String(w.dropFirst()).lowercased()] {
                take(i...i, .effort(e)); break
            }
        }

        // 3. Label.
        for i in live() where words[i].text.hasPrefix("@") && words[i].text.count > 1 {
            let (span, name) = resolveLabel(at: i, words: words, consumed: consumed, labels: directory.labels)
            take(i...(i + span - 1), .label(name))
            break
        }

        // 4. Destination.
        for i in live() where words[i].text.hasPrefix("#") && words[i].text.count > 1 {
            if let (span, dest) = resolveDestination(at: i, words: words, consumed: consumed, directory: directory) {
                take(i...(i + span - 1), .destination(dest))
            } else {
                let raw = words[i].text
                unresolved = EntryUnresolved(text: raw, range: words[i].range,
                                             name: String(raw.dropFirst()).replacingOccurrences(of: "-", with: " "))
            }
            break
        }

        // 5. Repeat: consecutive live words only, like a date phrase.
        if readsRepeat {
            let alive = live()
            for (pos, i) in alive.enumerated() {
                let run = alive[pos...].enumerated().prefix { $0.element == i + $0.offset }.map(\.element).prefix(3)
                if let (phrase, span) = RepeatPhrase.match(run.map { words[$0].text }) {
                    take(i...(i + span - 1), .repeats(phrase))
                    break
                }
            }
        }

        // 6. Date.
        let vocabulary = DatePhrases.buildSystemVocabulary(languages: languages, calendar: calendar)
        if let (day, hit) = QuickAddParser.matchDatePhrase(words.map(\.text), keep: live(), today: today,
                                                            calendar: calendar, vocabulary: vocabulary),
           let first = hit.min(), let last = hit.max() {
            take(first...last, .due(day))
        }

        let title = live().map { words[$0].text }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return EntryParse(title: title, tokens: tokens.sorted { $0.range.lowerBound < $1.range.lowerBound },
                          unresolvedDestination: unresolved)
    }

    // MARK: Resolution

    /// Words that may continue a multi-word name after `start`: contiguous, still live, not the
    /// start of a token of their own.
    private static func continuation(after start: Int, words: [EntryWord], consumed: Set<Int>) -> [Int] {
        var out: [Int] = []
        var i = start + 1
        while i < words.count, out.count < maxNameWords - 1, !consumed.contains(i), !EntryMatcher.startsToken(words[i].text) {
            out.append(i)
            i += 1
        }
        return out
    }

    private static func resolveLabel(at i: Int, words: [EntryWord], consumed: Set<Int>,
                                     labels: [EntryName]) -> (span: Int, name: String) {
        let rest = continuation(after: i, words: words, consumed: consumed)
        let first = String(words[i].text.dropFirst())
        for n in stride(from: rest.count + 1, through: 1, by: -1) {
            let parts = [first] + rest.prefix(n - 1).map { words[$0].text }
            let key = EntryMatcher.normalize(parts.joined(separator: " "))
            if let hit = labels.first(where: { EntryMatcher.normalize($0.name) == key }) { return (n, hit.name) }
        }
        return (1, first)
    }

    private static func resolveDestination(at i: Int, words: [EntryWord], consumed: Set<Int>,
                                           directory: EntryDirectory) -> (span: Int, dest: EntryDestination)? {
        let rest = continuation(after: i, words: words, consumed: consumed)
        let first = String(words[i].text.dropFirst())
        func key(_ n: Int) -> String {
            EntryMatcher.normalize(([first] + rest.prefix(n - 1).map { words[$0].text }).joined(separator: " "))
        }
        func destination(_ h: EntryMatcher.Hit) -> EntryDestination {
            EntryDestination(kind: h.kind, name: h.name.name, id: h.name.id)
        }
        let maxSpan = rest.count + 1
        // Exact then prefix, longest span first; then the loose tiers for one word only.
        for tier in [EntryMatchTier.exact, .prefix] {
            for n in stride(from: maxSpan, through: 1, by: -1) {
                let hits = EntryMatcher.rank(key: key(n), projects: directory.projects, areas: directory.areas, maxTier: tier)
                if let best = hits.first(where: { $0.tier == tier }) { return (n, destination(best)) }
            }
        }
        let hits = EntryMatcher.rank(key: key(1), projects: directory.projects, areas: directory.areas, maxTier: .contains)
        if let best = hits.first { return (1, destination(best)) }
        return nil
    }
}

/// Text plus the pills the user already committed, merged into what a submit creates.
public enum EntryDraft {

    /// - Parameter lineOffset: added to every typed range, for a caller that parsed one line
    ///   of a longer text and wants ranges in the whole text's offsets.
    ///
    /// A token still in the text beats a committed pill of the same slot: it is the newer
    /// instruction ("#other" typed over a prefilled project means the other project).
    public static func resolve(text: String, pills: [EntryPill], directory: EntryDirectory, today: Int,
                               languages: [String] = QuickAddParser.defaultLanguages,
                               calendar: Calendar = .current, lineOffset: Int = 0,
                               readsRepeat: Bool = false) -> EntryResolved {
        let parse = EntryParser.parse(text, directory: directory, today: today, languages: languages,
                                      calendar: calendar, readsRepeat: readsRepeat)
        var chips: [EntryChip] = []
        for slot in EntryPill.Slot.allCases {
            // A surface that cannot store a repeat never shows a committed repeat pill either.
            if slot == .repeats, !readsRepeat { continue }
            if let t = parse.token(slot) {
                chips.append(EntryChip(pill: t.pill,
                                       source: .typed((t.range.lowerBound + lineOffset)..<(t.range.upperBound + lineOffset))))
            } else if let p = pills.last(where: { $0.slot == slot }) {
                chips.append(EntryChip(pill: p, source: .committed))
            }
        }
        var unresolved = parse.unresolvedDestination
        if let u = unresolved { unresolved?.range = (u.range.lowerBound + lineOffset)..<(u.range.upperBound + lineOffset) }
        return EntryResolved(title: parse.title, chips: chips, unresolvedDestination: unresolved)
    }

    /// Pills to keep after an add that keeps them (batch entry): every attribute the entry
    /// carried, typed or committed, as committed pills.
    public static func pillsToKeep(after resolved: EntryResolved) -> [EntryPill] { resolved.pills }

    /// `pills` with `pill` in its slot, replacing what was there.
    public static func setting(_ pill: EntryPill, in pills: [EntryPill]) -> [EntryPill] {
        pills.filter { $0.slot != pill.slot } + [pill]
    }
}
