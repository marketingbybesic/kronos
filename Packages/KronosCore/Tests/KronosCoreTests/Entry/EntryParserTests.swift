import Testing
import Foundation
@testable import KronosCore

/// Hand-written expectation tables for grammar v2. Nothing here is computed by the code under
/// test; every row states by hand what the line must become.
enum EntryFixture {
    static let today = 20000
    static let languages = ["en", "hr"]

    static let hitList = EntryName("Hit list", id: UUID())
    static let hitParade = EntryName("Hit parade", id: UUID())
    static let homeReno = EntryName("Home renovation", id: UUID())
    static let workProject = EntryName("Work", id: UUID())
    static let acmeSkola = EntryName("Acme škola", id: UUID())
    static let homeArea = EntryName("Home", id: UUID())
    static let workArea = EntryName("Work", id: UUID())
    static let zagreb = EntryName("Đakovo", id: UUID())

    static let directory = EntryDirectory(
        projects: [hitList, hitParade, homeReno, workProject, acmeSkola, zagreb],
        areas: [homeArea, workArea],
        labels: [EntryName("deep work"), EntryName("Deep dive"), EntryName("finance")])

    static func parse(_ s: String, _ d: EntryDirectory = directory) -> EntryParse {
        EntryParser.parse(s, directory: d, today: today, languages: languages)
    }
}

struct EntryParserTests {
    typealias F = EntryFixture

    struct Row {
        var input: String
        var title: String
        var dest: (EntryDestination.Kind, String)?
        var label: String? = nil
        var priority: KPriority = .none
        var effort: KEffort? = nil
        var due: Int? = nil
    }

    static let rows: [Row] = [
        // Multi-word project, any case, anywhere in the line.
        Row(input: "#Hit list call mom", title: "call mom", dest: (.project, "Hit list")),
        Row(input: "#hit list call mom", title: "call mom", dest: (.project, "Hit list")),
        Row(input: "call mom #hit list", title: "call mom", dest: (.project, "Hit list")),
        Row(input: "buy #hit list milk", title: "buy milk", dest: (.project, "Hit list")),
        Row(input: "#HIT LIST call mom", title: "call mom", dest: (.project, "Hit list")),
        // Shorter keys: prefix, word-prefix, dashes as spaces.
        Row(input: "#hit call mom", title: "call mom", dest: (.project, "Hit list")),
        Row(input: "#list call mom", title: "call mom", dest: (.project, "Hit list")),
        Row(input: "#hit-list call mom", title: "call mom", dest: (.project, "Hit list")),
        Row(input: "#Hit_list call mom", title: "call mom", dest: (.project, "Hit list")),
        // Diacritics and the d-stroke fold.
        Row(input: "#acme skola review", title: "review", dest: (.project, "Acme škola")),
        Row(input: "#ACME-ŠKOLA review", title: "review", dest: (.project, "Acme škola")),
        Row(input: "#skola review", title: "review", dest: (.project, "Acme škola")),
        Row(input: "#dakovo review", title: "review", dest: (.project, "Đakovo")),
        // Same prefix, project and area: tier decides (exact area beats prefix project), then
        // list order (project before area).
        Row(input: "#home paint", title: "paint", dest: (.area, "Home")),
        Row(input: "#work report", title: "report", dest: (.project, "Work")),
        Row(input: "#hom paint", title: "paint", dest: (.project, "Home renovation")),
        // A title word that follows a finished name is never swallowed.
        Row(input: "#work on the report", title: "on the report", dest: (.project, "Work")),
        // A priority between the words ends the name.
        Row(input: "#hit !! list", title: "list", dest: (.project, "Hit list"), priority: .medium),
        // Several tokens at once.
        Row(input: "Send offer #hit list @finance !!! *m sutra", title: "Send offer", dest: (.project, "Hit list"),
            label: "finance", priority: .high, effort: .m, due: EntryFixture.today + 1),
        // Multi-word label: an existing label's words win; otherwise one word, verbatim.
        Row(input: "@deep work call mom", title: "call mom", dest: nil, label: "deep work"),
        Row(input: "@Deep Dive call mom", title: "call mom", dest: nil, label: "Deep dive"),
        Row(input: "@deep call mom", title: "call mom", dest: nil, label: "deep"),
        Row(input: "@newlabel call mom", title: "call mom", dest: nil, label: "newlabel"),
        // Plain text stays plain.
        Row(input: "Call the accountant about Q3", title: "Call the accountant about Q3", dest: nil),
        Row(input: "C# is a language", title: "C# is a language", dest: nil),
        Row(input: "# alone", title: "# alone", dest: nil),
    ]

    @Test func table() {
        for row in Self.rows {
            let p = F.parse(row.input)
            let got = "\(row.input) -> title=\(p.title) dest=\(String(describing: p.destination.map { "\($0.kind) \($0.name)" })) label=\(String(describing: p.labelName)) prio=\(p.priority) effort=\(String(describing: p.effort)) due=\(String(describing: p.dueDay))"
            #expect(p.title == row.title, "\(got)")
            #expect(p.destination?.name == row.dest?.1, "\(got)")
            if let k = row.dest?.0 { #expect(p.destination?.kind == k, "\(got)") }
            #expect(p.labelName == row.label, "\(got)")
            #expect(p.priority == row.priority, "\(got)")
            #expect(p.effort == row.effort, "\(got)")
            #expect(p.dueDay == row.due, "\(got)")
        }
    }

    @Test func idIsCarriedToTheDestination() {
        #expect(F.parse("#hit list x").destination?.id == F.hitList.id)
        #expect(F.parse("#home x").destination?.id == F.homeArea.id)
        #expect(F.parse("#home x").destination?.isNew == false)
    }

    // The first # token decides; a second one stays literal text in the title, resolved or not.
    @Test func twoHashTokens() {
        let p = F.parse("#hit list #work do thing")
        #expect(p.destination?.name == "Hit list")
        #expect(p.title == "#work do thing")
        #expect(p.unresolvedDestination == nil)
        let q = F.parse("#nosuch #work do thing")
        #expect(q.destination == nil)
        #expect(q.unresolvedDestination?.text == "#nosuch")
        #expect(q.title == "#nosuch #work do thing")
    }

    @Test func unknownProjectIsUnresolvedAndStaysInTheTitle() {
        let p = F.parse("Fix bike #nepostojeci-projekt now")
        #expect(p.destination == nil)
        #expect(p.unresolvedDestination?.text == "#nepostojeci-projekt")
        #expect(p.unresolvedDestination?.name == "nepostojeci projekt")
        #expect(p.unresolvedDestination?.range == 9..<29)
        #expect(p.title == "Fix bike #nepostojeci-projekt now")
    }

    @Test func tokenRangesAreUTF16OffsetsOfTheWholeToken() {
        let p = F.parse("call mom #hit list")
        #expect(p.token(.destination)?.range == 9..<18)
        let q = F.parse("a !! b #acme škola c")
        #expect(q.token(.priority)?.range == 2..<4)
        #expect(q.token(.destination)?.range == 7..<18)
        // Surrogate pairs count as two units.
        let r = F.parse("😀 #work x")
        #expect(r.token(.destination)?.range == 3..<8)
    }

    // Ties between equally good matches go to the most recently used.
    @Test func recencyBreaksTies() {
        var recent = F.hitParade
        recent.lastUsed = Date(timeIntervalSince1970: 1_000)
        var older = F.hitList
        older.lastUsed = Date(timeIntervalSince1970: 10)
        let d = EntryDirectory(projects: [older, recent])
        #expect(F.parse("#hit x", d).destination?.name == "Hit parade")
        // No recency at all: list order.
        #expect(F.parse("#hit x", EntryDirectory(projects: [F.hitList, F.hitParade])).destination?.name == "Hit list")
        // A used one never beats a better tier.
        #expect(F.parse("#hit list x", d).destination?.name == "Hit list")
    }

    // Tokens other than # keep their old semantics.
    @Test func unchangedSemantics() {
        #expect(F.parse("Task !!!!!").priority == .none)
        #expect(F.parse("Task !!!!!").title == "Task !!!!!")
        #expect(F.parse("a *s b ~xl").effort == .xl)               // last one wins
        #expect(F.parse("a ! b !!!").priority == .low)             // first one wins
        #expect(F.parse("a @x @y").labelName == "x")
        #expect(F.parse("a @x @y").title == "a @y")
        #expect(F.parse("Pay rent 2030-01-15").dueDay == Day.parseISO("2030-01-15"))
        #expect(F.parse("5*3 plan").title == "5*3 plan")
        #expect(F.parse("~/Downloads sort").title == "~/Downloads sort")
    }

    @Test func hrAndEnDates() {
        #expect(F.parse("call mom tomorrow").dueDay == F.today + 1)
        #expect(F.parse("nazovi mamu sutra").dueDay == F.today + 1)
        #expect(F.parse("nazovi mamu prekosutra #hit list").dueDay == F.today + 2)
        #expect(F.parse("nazovi mamu prekosutra #hit list").title == "nazovi mamu")
        #expect(F.parse("call mom in 3 days").dueDay == F.today + 3)
        #expect(F.parse("nazovi za 3 dana").dueDay == F.today + 3)
    }

    // The old API is the v2 engine with projects only: the Hit list bug is fixed there too.
    @Test func oldParserDelegatesToTheSameGrammar() {
        let p = QuickAddParser().parse("#Hit list call mom", projects: ["Hit list", "Work"], today: F.today)
        #expect(p.projectName == "Hit list")
        #expect(p.title == "call mom")
        #expect(p.unresolvedProjectToken == nil)
    }
}

struct EntryDraftTests {
    typealias F = EntryFixture

    @Test func committedPillsAreKeptAndTypedTokensWin() {
        let prefilled = EntryPill.destination(EntryDestination(kind: .project, name: "Work", id: F.workProject.id))
        let pills: [EntryPill] = [prefilled, .priority(.urgent)]
        // Nothing typed: the pills are the result.
        var r = EntryDraft.resolve(text: "call mom", pills: pills, directory: F.directory, today: F.today, languages: F.languages)
        #expect(r.title == "call mom")
        #expect(r.destination?.name == "Work")
        #expect(r.priority == .urgent)
        #expect(r.chips.map(\.source) == [.committed, .committed])
        // A typed # beats the committed destination; the pill of another slot stays.
        r = EntryDraft.resolve(text: "call mom #hit list", pills: pills, directory: F.directory, today: F.today, languages: F.languages)
        #expect(r.destination?.name == "Hit list")
        #expect(r.priority == .urgent)
        #expect(r.chip(.destination)?.source == .typed(9..<18))
        #expect(r.chip(.priority)?.source == .committed)
        #expect(r.title == "call mom")
    }

    @Test func chipsAreInSlotOrder() {
        let r = EntryDraft.resolve(text: "x sutra !! *l @finance #hit list", pills: [], directory: F.directory,
                                   today: F.today, languages: F.languages)
        #expect(r.chips.map { $0.pill.slot } == [.destination, .label, .priority, .effort, .due])
    }

    @Test func lineOffsetShiftsTypedRanges() {
        let r = EntryDraft.resolve(text: "call #hit list", pills: [], directory: F.directory, today: F.today,
                                   languages: F.languages, lineOffset: 100)
        #expect(r.chip(.destination)?.source == .typed(105..<114))
        let u = EntryDraft.resolve(text: "call #nosuch", pills: [], directory: F.directory, today: F.today,
                                   languages: F.languages, lineOffset: 100)
        #expect(u.unresolvedDestination?.range == 105..<112)
    }

    @Test func keepingPillsTurnsTypedTokensIntoCommittedOnes() {
        let r = EntryDraft.resolve(text: "call #hit list !!", pills: [.effort(.s)], directory: F.directory,
                                   today: F.today, languages: F.languages)
        let kept = EntryDraft.pillsToKeep(after: r)
        #expect(kept.count == 3)
        #expect(kept.contains(.priority(.medium)))
        #expect(kept.contains(.effort(.s)))
        #expect(kept.contains { if case .destination(let d) = $0 { return d.name == "Hit list" } else { return false } })
    }

    @Test func settingReplacesTheSlot() {
        let a = EntryPill.priority(.low), b = EntryPill.priority(.high), c = EntryPill.effort(.m)
        #expect(EntryDraft.setting(b, in: [a, c]) == [c, b])
        #expect(EntryDraft.setting(a, in: []) == [a])
    }
}

struct EntryEditTests {
    @Test func removingTidiesWhitespace() {
        let rows: [(text: String, range: Range<Int>, out: String, caret: Int)] = [
            ("call #hit list mom", 5..<14, "call mom", 5),     // middle: one space survives
            ("call mom #hit list", 9..<18, "call mom", 8),     // end: trailing space goes
            ("#hit list call", 0..<9, "call", 0),             // start: leading space goes
            ("#hit", 0..<4, "", 0),
            ("a\n#hit b", 2..<6, "a\nb", 2),                  // line start after a newline
            ("a #x\nb", 2..<4, "a\nb", 1),                    // line end before a newline
            ("abc", 5..<9, "abc", 3),                         // out of range: clamped, nothing cut
        ]
        for r in rows {
            let got = EntryEdit.removing(r.range, from: r.text)
            #expect(got.text == r.out, "\(r.text) \(r.range)")
            #expect(got.caret == r.caret, "\(r.text) \(r.range)")
        }
    }
}
