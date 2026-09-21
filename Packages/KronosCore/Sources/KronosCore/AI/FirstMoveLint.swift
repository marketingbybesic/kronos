// KronosCore/AI — first-move validator.
//
// "firstMove must be a concrete, zero-decision physical action" is not a
// property a prompt can guarantee, so this makes it a checked one. Pure,
// synchronous, no network, no state.

import Foundation

public enum LintVerdict: Equatable, Sendable {
    case pass
    case fail(reason: String)

    public var isPass: Bool { self == .pass }
}

/// Validates a candidate `firstMove` string against seven rules (plus one
/// dread-mode rule), in both HR and EN.
public enum FirstMoveLint {

    // MARK: R1 — allowlisted opening verb

    static let allowVerbsEN: Set<String> = [
        "open", "write", "type", "call", "dial", "send", "reply", "forward", "print", "read",
        "put", "click", "copy", "paste", "draft", "create", "run", "add", "delete", "rename",
        "move", "save", "download", "upload", "attach", "record", "photograph", "measure",
        "count", "sign", "scan", "pay", "book", "order", "email", "text", "message", "ask",
        "tell", "answer", "start"
    ]
    static let allowVerbsHR: Set<String> = [
        "otvori", "napiši", "upiši", "nazovi", "pošalji", "odgovori", "proslijedi", "isprintaj",
        "pročitaj", "stavi", "klikni", "kopiraj", "zalijepi", "skiciraj", "napravi", "pokreni",
        "dodaj", "obriši", "preimenuj", "premjesti", "spremi", "preuzmi", "učitaj", "priloži",
        "snimi", "fotografiraj", "izmjeri", "prebroji", "potpiši", "skeniraj", "plati",
        "rezerviraj", "naruči", "pitaj", "reci", "javi"
    ]

    // MARK: R4 — decision verbs (banned anywhere in the string)

    static let decisionPhrasesEN: [String] = [
        "decide", "choose", "pick", "plan", "think", "consider", "research", "figure out",
        "work out", "review options", "evaluate", "assess", "brainstorm", "explore",
        "look into", "determine", "prioritize", "organize your thoughts", "get started on",
        "start working on", "begin working on", "work on", "handle", "deal with", "sort out",
        "tackle", "address"
    ]
    static let decisionPhrasesHR: [String] = [
        "odluči", "odaberi", "izaberi", "isplaniraj", "razmisli", "promisli", "istraži",
        "prouči", "razmotri", "procijeni", "sredi", "posloži", "pozabavi se", "riješi",
        "krenina", "počni raditi", "radi na"
    ]

    // MARK: R6 — hedging / conditionals

    static let hedgePhrasesEN: [String] = [
        "if ", "try to", "maybe", "see if", "check whether", "as needed"
    ]
    static let hedgePhrasesHR: [String] = [
        "ako ", "pokušaj", "možda", "provjeri je li", "po potrebi"
    ]

    // MARK: R7 — meta-tasks about the task system

    static let metaPhrasesEN: [String] = [
        "add a subtask", "break this down", "break this task down", "estimate", "triage",
        "write down what", "make a list of what"
    ]
    static let metaPhrasesHR: [String] = [
        "razbij na", "procijeni koliko"
    ]

    // MARK: R3 — generic nouns that never satisfy "specific object"

    static let genericObjectsEN: Set<String> = ["document", "thing", "it", "file", "stuff"]
    static let genericObjectsHR: Set<String> = ["dokument", "stvar", "to", "datoteku"]

    // MARK: dreadMode R8 — verbs that must be bounded to an artifact, not the encounter

    static let dreadRiskyVerbsEN: Set<String> = ["call", "send", "pay", "reply", "tell"]
    static let dreadRiskyVerbsHR: Set<String> = ["nazovi", "pošalji", "plati", "odgovori", "reci"]
    /// Object tokens that show the move approaches an artifact rather than
    /// performing the aversive act in full.
    static let dreadBoundingWordsEN: Set<String> = ["draft", "line", "first"]
    static let dreadBoundingWordsHR: Set<String> = ["draft", "skicu", "nacrt", "prvu", "prvi"]

    /// Entry point. `language` selects the allowlist/phrase set; `dreadMode`
    /// applies R8 in addition to R1–R7.
    public static func lint(_ move: String, language: Lang, dreadMode: Bool) -> LintVerdict {
        let trimmed = move.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard !trimmed.isEmpty else { return .fail(reason: "empty") }

        let words = trimmed.split(separator: " ").map(String.init)
        guard let firstWord = words.first else { return .fail(reason: "empty") }
        let firstLower = firstWord.lowercased()
        let lowerFull = trimmed.lowercased()
        let allowlist = language == .hr ? allowVerbsHR : allowVerbsEN

        // R2 (length) is checked FIRST: F7 fails both R2 and R5 (and even
        // matches an R4 word), but the spec's expected reason is "too long"
        // specifically, so the coarsest, cheapest check wins first.
        if words.count > 12 || trimmed.count > 100 {
            return .fail(reason: "too long")
        }

        // R4, R6 and R7 are checked BEFORE R1: several catalogued cases (F1,
        // F2, F6, F8, F9) also fail R1 because their opening word is not
        // allowlisted, but the spec's expected reason string names the more
        // specific rule, not R1's generic one.
        let decisionPhrases = language == .hr ? decisionPhrasesHR : decisionPhrasesEN
        if decisionPhrases.contains(where: { lowerFull.contains($0) }) {
            return .fail(reason: "decision verb")
        }
        let hedges = language == .hr ? hedgePhrasesHR : hedgePhrasesEN
        if hedges.contains(where: { lowerFull.contains($0) }) {
            // "check" alone reading a specific thing is allowed; that is a
            // separate verb (R1), not a hedge phrase, so no exception needed
            // here since none of the hedge phrases are "check" by itself.
            return .fail(reason: "hedging")
        }
        let metas = language == .hr ? metaPhrasesHR : metaPhrasesEN
        if metas.contains(where: { lowerFull.contains($0) }) {
            return .fail(reason: "meta-task")
        }

        // R1
        guard allowlist.contains(firstLower) else {
            return .fail(reason: "not an allowlisted opening verb")
        }
        // "start"/"pokreni" require a named artifact after it (folded into R3's
        // generic-object check, since a bare "start the timer" fails there too).

        // R5 — conjunctive chaining
        if let reason = checkChaining(trimmed, language: language) { return .fail(reason: reason) }

        // R3 — object specificity
        guard hasSpecificObject(trimmed, words: words, language: language) else {
            return .fail(reason: "no specific object")
        }

        // dreadMode R8
        if dreadMode, let reason = checkDreadBounded(trimmed, firstLower: firstLower, language: language) {
            return .fail(reason: reason)
        }

        return .pass
    }

    // MARK: R5

    private static func checkChaining(_ text: String, language: Lang) -> String? {
        let lower = text.lowercased()
        let connectors = language == .hr ? [" i ", " pa ", " zatim "] : [" and ", " then "]
        if lower.contains(";") || lower.contains(" → ") { return "chaining" }
        let count = connectors.reduce(0) { acc, c in acc + lower.components(separatedBy: c).count - 1 }
        if count > 1 { return "chaining" }
        // A single connector is allowed only when it joins two clauses about
        // the same object; enforcing that precisely would need a parser, so
        // we accept the single-connector case (matches P4 in the spec table)
        // and only reject 2+ connectors, which always means independent
        // actions (matches F5/F7).
        return nil
    }

    // MARK: R3
    //
    // Spec wording: "The move must name at least one specific object: a
    // proper noun ..., a file name or extension, an app name, a URL or path,
    // a quoted string, or a number. A move consisting only of the verb plus
    // generic nouns (...) fails." This is a blocklist check, not a positive
    // whitelist: an ordinary concrete noun ("rečenicu", "odlomak", "photos")
    // is a specific-enough object on its own. Only the named generic filler
    // words (and the shape "verb + generic noun and nothing else") fail —
    // confirmed by P10 (`Napiši jednu rečenicu o cijeni u bilješke`), which
    // has no capitalised word, number, path or quote yet must PASS, versus
    // F4 (`Open the document`), which must FAIL.

    private static func hasSpecificObject(_ text: String, words: [String], language: Lang) -> Bool {
        let generic = language == .hr ? genericObjectsHR : genericObjectsEN
        let remainder = words.dropFirst().joined(separator: " ").lowercased()
            .trimmingCharacters(in: .whitespaces)
        guard !remainder.isEmpty else { return false }

        // Strip common leading articles/prepositions so "the document" and
        // "document" are judged the same way.
        let stripped = stripLeadingFiller(remainder, language: language)

        // Fails only when what remains IS one of the named generic phrases
        // (word-for-word), not merely when it contains one as a substring —
        // "Open the Acme folder" must not fail because "folder" is close
        // to "file" in spirit; it fails only on an exact generic-noun match.
        if generic.contains(stripped) { return false }
        return true
    }

    private static func stripLeadingFiller(_ s: String, language: Lang) -> String {
        let fillers = language == .hr
            ? ["za ", "od ", "u "]
            : ["the ", "a ", "an "]
        var out = s
        for f in fillers where out.hasPrefix(f) { out = String(out.dropFirst(f.count)) }
        return out
    }

    // MARK: R8 (dreadMode)

    private static func checkDreadBounded(_ text: String, firstLower: String, language: Lang) -> String? {
        let riskyVerbs = language == .hr ? dreadRiskyVerbsHR : dreadRiskyVerbsEN
        guard riskyVerbs.contains(firstLower) else { return nil }
        let boundingWords = language == .hr ? dreadBoundingWordsHR : dreadBoundingWordsEN
        let lower = text.lowercased()
        let isBounded = boundingWords.contains { lower.contains($0) }
        return isBounded ? nil : "bounded opener required in dread mode"
    }
}

// MARK: - Deterministic first-move templates

/// Chosen by the first matching rule, in order. Every template passes its
/// own lint by construction (asserted by `deterministicFirstMoveAlwaysPassesTheLint`).
///
/// **Amendment (2026-09-19).** The original §2.3 templates always embedded
/// the raw title after "Open"/"Otvori" (`Open <title> and write the first
/// line`). For a title that already starts with an imperative verb — the
/// common case, since users write tasks like "Send the invoice" — this
/// produced ungrammatical output: "Open Send the September invoice to Alex
/// and write the first line." `leadingVerbFamily` detects the verb and
/// routes to a natural, verb-specific opener instead; a title with no
/// recognisable leading verb still gets the original noun-phrase template,
/// which was never wrong for that case.
public enum DeterministicFirstMove {
    public static func generate(title: String,
                                firstMoveURL: String?,
                                hasOpenSubtask: Bool,
                                notesNonEmpty: Bool,
                                dread: Bool,
                                language appLanguage: Lang) -> String {
        // The move is read right under the title, so it follows the TITLE language; the app
        // language only decides when the title gives no signal (it shipped "Open Nazovi Ivanu
        // oko termina and write the first line" for a Croatian task in an English app).
        let firstWord = title.split(separator: " ").first.map { $0.lowercased() } ?? ""
        let language: Lang = verbMapHR[firstWord] != nil ? .hr
            : verbMapEN[firstWord] != nil ? .en
            : detectLanguage(title) == .hr ? .hr : appLanguage
        if let url = firstMoveURL, let host = hostOrFilename(url) {
            return language == .hr ? "Otvori \(host)" : "Open \(host)"
        }
        let verb = leadingVerbFamily(title, language: language)

        // dread ALWAYS gets the <=2-minute opener,
        // checked before subtask/notes so a dreaded task with notes still
        // gets the bounded opener, not the longer "read your notes" move.
        if dread {
            return dreadOpener(title: title, verb: verb, language: language)
        }
        if hasOpenSubtask {
            return subtaskOpener(title: title, verb: verb, language: language)
        }
        if notesNonEmpty {
            return notesOpener(title: title, verb: verb, language: language)
        }
        return defaultOpener(title: title, verb: verb, language: language)
    }

    // MARK: Verb-family detection

    /// A recognised opening verb, mapped to the natural action it implies.
    /// `object` is the title with the verb (and, for EN, a leading "the")
    /// stripped — what remains after "Send", "Call", etc.
    private enum VerbFamily { case sendEmail, call, write, pay, book, buy, fix, review, prepare }

    private static let verbMapEN: [String: VerbFamily] = [
        "send": .sendEmail, "email": .sendEmail, "call": .call, "write": .write,
        "pay": .pay, "book": .book, "buy": .buy, "fix": .fix, "review": .review,
        "prepare": .prepare
    ]
    private static let verbMapHR: [String: VerbFamily] = [
        // infinitive and imperative forms, per the team's verb list.
        "poslati": .sendEmail, "pošalji": .sendEmail,
        "nazvati": .call, "nazovi": .call,
        "napisati": .write, "napiši": .write,
        "platiti": .pay, "plati": .pay,
        "rezervirati": .book, "rezerviraj": .book,
        "kupiti": .buy, "kupi": .buy,
        "popraviti": .fix, "popravi": .fix,
        "pregledati": .review, "pregledaj": .review,
        "pripremiti": .prepare, "pripremi": .prepare
    ]

    /// `(family, object)` when the title's first word is a recognised verb;
    /// `nil` otherwise, in which case the original noun-phrase templates
    /// (correct for a title that is not itself an imperative) still apply.
    ///
    /// `object` is the single most specific token in the remainder — the
    /// first capitalised word after the verb, which in a title like "Send
    /// the September invoice to Alex" or "Nazovi Alexa oko isporuke" is the
    /// person/place the verb targets, not the whole trailing noun phrase
    /// ("September invoice to" is not what a natural sentence names).
    /// Falls back to empty when nothing capitalised follows.
    private static func leadingVerbFamily(_ title: String, language: Lang) -> (VerbFamily, String)? {
        let words = title.split(separator: " ").map(String.init)
        guard let first = words.first?.lowercased() else { return nil }
        let map = language == .hr ? verbMapHR : verbMapEN
        guard let family = map[first] else { return nil }
        let rest = words.dropFirst()
        let object = rest.last { w in
            guard let c = w.first else { return false }
            return c.isUppercase
        } ?? ""
        return (family, object)
    }

    // MARK: Openers

    private static func defaultOpener(title: String, verb: (VerbFamily, String)?, language: Lang) -> String {
        guard let (family, object) = verb else {
            // No recognised leading verb: the title is a noun phrase, so the
            // original template is already grammatical.
            return language == .hr
                ? "Otvori bilješke ovog zadatka i napiši prvu rečenicu"
                : "Open the notes for this task and write the first line"
        }
        return familyOpener(family, object: object, language: language)
    }

    /// One natural, concrete opener per verb family. Every branch names a
    /// specific app/artifact (R3) and stays within R2's 12-word cap. `object`
    /// is already a single token (see `leadingVerbFamily`), so no further
    /// truncation is needed here.
    private static func familyOpener(_ family: VerbFamily, object obj: String, language: Lang) -> String {
        switch (family, language) {
        case (.sendEmail, .en): return obj.isEmpty
            ? "Open Mail and start a new message." : "Open Mail and start a new message to \(obj)."
        case (.sendEmail, .hr): return obj.isEmpty
            ? "Otvori Mail i započni novu poruku." : "Otvori Mail i započni novu poruku za \(obj)."
        case (.call, .en): return obj.isEmpty
            ? "Open Contacts and find the number." : "Open Contacts and find \(obj)'s number."
        case (.call, .hr): return obj.isEmpty
            ? "Otvori Kontakte i pronađi broj." : "Otvori Kontakte i pronađi broj za \(obj)."
        case (.write, .en): return "Open a blank document and type the title."
        case (.write, .hr): return "Otvori prazan dokument i upiši naslov."
        case (.pay, .en): return "Open your banking app and log in."
        case (.pay, .hr): return "Otvori bankovnu aplikaciju i prijavi se."
        case (.book, .en): return obj.isEmpty
            ? "Open the booking site and search." : "Open the booking site and search for \(obj)."
        case (.book, .hr): return obj.isEmpty
            ? "Otvori stranicu za rezervacije i pretraži." : "Otvori stranicu za rezervacije i pretraži \(obj)."
        case (.buy, .en): return obj.isEmpty
            ? "Open the store and search." : "Open the store and search for \(obj)."
        case (.buy, .hr): return obj.isEmpty
            ? "Otvori trgovinu i pretraži." : "Otvori trgovinu i pretraži \(obj)."
        case (.fix, .en): return "Open the item and look at what is broken."
        case (.fix, .hr): return "Otvori stvar i pogledaj što je pokvareno."
        case (.review, .en): return obj.isEmpty
            ? "Open the document and read the first page." : "Open \(obj) and read the first page."
        case (.review, .hr): return obj.isEmpty
            ? "Otvori dokument i pročitaj prvu stranicu." : "Otvori \(obj) i pročitaj prvu stranicu."
        case (.prepare, .en): return "Open a blank note and list what is needed."
        case (.prepare, .hr): return "Otvori praznu bilješku i popiši što treba."
        }
    }

    private static func subtaskOpener(title: String, verb: (VerbFamily, String)?, language: Lang) -> String {
        guard verb != nil else {
            return language == .hr
                ? "Otvori ovaj zadatak i pročitaj prvi podzadatak"
                : "Open this task and read subtask 1"
        }
        // A verb-led title has no natural noun-phrase slot for "Open X"; the
        // subtask itself is still the concrete next step regardless of verb.
        return language == .hr ? "Otvori prvi podzadatak i pročitaj ga" : "Open subtask 1 and read it"
    }

    private static func notesOpener(title: String, verb: (VerbFamily, String)?, language: Lang) -> String {
        guard verb != nil else {
            return language == .hr
                ? "Otvori bilješke ovog zadatka i čitaj ih 2 minute"
                : "Open the notes of this task and read them for 2 minutes"
        }
        return language == .hr
            ? "Otvori bilješke i čitaj ih 2 minute"
            : "Open the notes and read them for 2 minutes"
    }

    /// The dread rule: honest execution time
    /// under two minutes, at every energy level, regardless of verb family.
    private static func dreadOpener(title: String, verb: (VerbFamily, String)?, language: Lang) -> String {
        guard let (_, object) = verb, !object.isEmpty else {
            return language == .hr
                // The move is shown under the title, so it never embeds a cut-off title
                // (it produced "about Reply to Alex about the in the notes").
                ? "Napiši u bilješke jednu rečenicu o ovom zadatku"
                : "Write one sentence about this task in the notes"
        }
        let obj = truncateWords(object, to: 4)
        return language == .hr
            ? "Napiši jednu rečenicu o \(obj) u bilješke"
            : "Write one sentence about \(obj) in the notes"
    }

    /// Truncates by word count first (to respect R2's 12-word cap once
    /// embedded in a template), then by character count as a second cap.
    private static func truncateWords(_ s: String, to maxWords: Int, maxChars: Int = 40) -> String {
        let words = s.split(separator: " ")
        let limited = words.prefix(maxWords).joined(separator: " ")
        guard limited.count > maxChars else { return limited }
        let idx = limited.index(limited.startIndex, offsetBy: maxChars)
        let head = String(limited[..<idx])
        if let lastSpace = head.lastIndex(of: " ") { return String(head[..<lastSpace]) }
        return head
    }

    private static func hostOrFilename(_ urlString: String) -> String? {
        if let url = URL(string: urlString), let host = url.host { return host }
        return (urlString as NSString).lastPathComponent
    }
}
