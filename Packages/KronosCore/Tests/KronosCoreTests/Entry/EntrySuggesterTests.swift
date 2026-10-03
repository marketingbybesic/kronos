import Testing
import Foundation
@testable import KronosCore

struct EntrySuggesterTests {
    typealias F = EntryFixture

    static func suggest(_ text: String, caret: Int? = nil, _ d: EntryDirectory = F.directory) -> EntrySuggestions {
        EntrySuggester.suggest(text: text, caret: caret ?? text.utf16.count, directory: d, today: F.today, languages: F.languages)
    }

    /// "kind:name" per item, "+kind:name" for a create suggestion.
    static func names(_ s: EntrySuggestions) -> [String] {
        s.items.map { item in
            switch item.pill {
            case .destination(let d): return (item.isCreate ? "+" : "") + "\(d.kind):\(d.name)"
            case .label(let n): return (item.isCreate ? "+" : "") + "label:\(n)"
            case .priority(let p): return "priority:\(p.rawValue)"
            case .effort(let e): return "effort:\(e.rawValue)"
            case .due(let d): return "due:\(d - F.today):\(item.title)"
            case .repeats(let r): return "repeat:\(r.every):\(r.unit.rawValue)"
            }
        }
    }

    // MARK: destinations

    @Test func hashPrefixRanksTiersThenListOrder() {
        // "hi": prefix = Hit list, Hit parade; fuzzy (h..i in order) = Home renovation; then create.
        let s = Self.suggest("#hi")
        #expect(s.active == EntryActiveToken(sigil: .destination, range: 0..<3, query: "hi"))
        #expect(Self.names(s) == ["project:Hit list", "project:Hit parade", "project:Home renovation", "+project:hi"])
        #expect(s.items.map(\.tier) == [.prefix, .prefix, .fuzzy, nil])
    }

    @Test func multiWordQueryNarrowsToTheNameAndOffersNoCreate() {
        let s = Self.suggest("#hit li")
        #expect(s.active?.query == "hit li")
        #expect(Self.names(s) == ["project:Hit list"])
        #expect(Self.names(Self.suggest("#hit list")) == ["project:Hit list"])
    }

    @Test func exactMatchOffersNoCreate() {
        #expect(Self.names(Self.suggest("#work")) == ["project:Work", "area:Work"])
        #expect(Self.names(Self.suggest("#home")) == ["area:Home", "project:Home renovation"])
    }

    @Test func trailingSpaceFinishesTheWord() {
        // "#hit list " : only names continuing at a word boundary, no create.
        #expect(Self.names(Self.suggest("#hit list ")) == ["project:Hit list"])
        // "#hit " : Hit list and Hit parade continue "hit " ; no create.
        #expect(Self.names(Self.suggest("#hit ")) == ["project:Hit list", "project:Hit parade"])
        // "#nosuch " : nothing continues it, so the caret is back in the title.
        #expect(Self.suggest("#nosuch ").active == nil)
    }

    @Test func wordWithNoMatchOffersCreateWithDashesAsSpaces() {
        let s = Self.suggest("#brand-new")
        #expect(Self.names(s) == ["+project:brand new"])
        if case .destination(let d) = s.items[0].pill { #expect(d.isNew && d.id == nil && d.kind == .project) } else { Issue.record("not a destination") }
        #expect(s.items[0].isCreate)
    }

    // An issue reference is not a project to create; letters-with-digits still are.
    @Test func numbersOnlyOffersNoCreate() {
        #expect(Self.suggest("Fix #123").active == nil)
        #expect(Self.names(Self.suggest("Fix #2fa")) == ["+project:2fa"])
        #expect(Self.suggest("see @42").active == nil)
    }

    @Test func caretInTheMiddleAndTokenInTheMiddleOfText() {
        // "call mom #hit list" caret at the end: range covers the whole multi-word token.
        let s = Self.suggest("call mom #hit list")
        #expect(s.active == EntryActiveToken(sigil: .destination, range: 9..<18, query: "hit list"))
        // Caret inside "#hit": query is what is before the caret, range reaches the word end.
        let m = Self.suggest("#hit list", caret: 3)
        #expect(m.active == EntryActiveToken(sigil: .destination, range: 0..<4, query: "hi"))
        // Caret in the title before the token: no list.
        #expect(Self.suggest("call mom #hit list", caret: 4).active == nil)
    }

    @Test func emptyQueryListsRecentFirst() {
        var work = F.workProject
        work.lastUsed = Date(timeIntervalSince1970: 500)
        var area = F.homeArea
        area.lastUsed = Date(timeIntervalSince1970: 100)
        let d = EntryDirectory(projects: [F.hitList, work, F.homeReno], areas: [area, F.workArea])
        #expect(Self.names(Self.suggest("#", d)) == ["project:Work", "area:Home", "project:Hit list", "project:Home renovation", "area:Work"])
    }

    @Test func recencyOrdersEqualTiers() {
        var parade = F.hitParade
        parade.lastUsed = Date(timeIntervalSince1970: 5)
        let d = EntryDirectory(projects: [F.hitList, parade])
        #expect(Self.names(Self.suggest("#hit", d)).prefix(2) == ["project:Hit parade", "project:Hit list"])
    }

    @Test func diacriticsAndDStroke() {
        #expect(Self.names(Self.suggest("#skola")).first == "project:Acme škola")
        #expect(Self.names(Self.suggest("#ŠKOLA")).first == "project:Acme škola")
        #expect(Self.names(Self.suggest("#dak")).first == "project:Đakovo")
    }

    // MARK: labels

    @Test func labels() {
        #expect(Self.names(Self.suggest("@dee")) == ["label:deep work", "label:Deep dive", "+label:dee"])
        #expect(Self.names(Self.suggest("@deep work")) == ["label:deep work"])   // exact: no create
        #expect(Self.suggest("@dee").active?.sigil == .label)
        #expect(Self.names(Self.suggest("x @fin")) == ["label:finance", "+label:fin"])
    }

    // MARK: priority and effort

    @Test func priority() {
        #expect(Self.names(Self.suggest("a !")) == ["priority:1", "priority:2", "priority:3", "priority:4"])
        #expect(Self.names(Self.suggest("a !!")) == ["priority:2", "priority:1", "priority:3", "priority:4"])
        #expect(Self.suggest("a !!").active == EntryActiveToken(sigil: .priority, range: 2..<4, query: "!!"))
        #expect(Self.suggest("a !!!!!").active == nil)
    }

    @Test func effort() {
        #expect(Self.names(Self.suggest("a *")) == ["effort:2", "effort:1", "effort:3", "effort:4", "effort:5"])
        #expect(Self.names(Self.suggest("a **")) == ["effort:3", "effort:1", "effort:2", "effort:4", "effort:5"])
        #expect(Self.names(Self.suggest("a *x")) == ["effort:1", "effort:5"])
        #expect(Self.names(Self.suggest("a ~l")) == ["effort:4"])
        #expect(Self.suggest("a *q").active == nil)
        #expect(Self.suggest("a ****").active == nil)
        // A lone star opening a line is a bullet, not an effort.
        #expect(Self.suggest("*").active == nil)
        #expect(Self.suggest("task\n*").active == nil)
        #expect(Self.suggest("5*3").active == nil)
    }

    // MARK: dates

    @Test func datePrefixSuggestsTheResolvedDay() {
        let s = Self.suggest("buy milk tom")
        #expect(s.active == EntryActiveToken(sigil: .date, range: 9..<12, query: "tom"))
        #expect(Self.names(s) == ["due:1:tomorrow"])
        // Croatian vocabulary.
        #expect(Self.names(Self.suggest("kupi mlijeko sut")) == ["due:1:sutra"])
        // Two-word phrase, range starts at the first word.
        let w = Self.suggest("do next we")
        #expect(w.active == EntryActiveToken(sigil: .date, range: 3..<10, query: "next we"))
        #expect(Self.names(w) == ["due:7:next week", "due:5:next wednesday"])
        // "za 3 d" completes the unit.
        #expect(Self.names(Self.suggest("nazovi za 3 d")) == ["due:3:za 3 dana"])
        #expect(Self.names(Self.suggest("call in 2 we")) == ["due:14:in 2 weeks"])
    }

    @Test func completeDatePhrasesAreOfferedAsTyped() {
        let day = Day.parseISO("2025-09-25")!
        let s = Self.suggest("pay 25.9.")
        #expect(s.items.first?.pill == .due(day))
        #expect(s.items.first?.title == "25.9.")
        #expect(Self.suggest("pay 2030-01-15").items.first?.pill == .due(Day.parseISO("2030-01-15")!))
    }

    @Test func plainTitleTextHasNoList() {
        #expect(Self.suggest("buy milk").active == nil)
        #expect(Self.suggest("buy milk", caret: 0).active == nil)
        #expect(Self.suggest("").active == nil)
        #expect(Self.suggest("su").active == nil)          // two letters: too short to be a date word
        #expect(Self.suggest("buy milk ").active == nil)   // caret in whitespace after a plain word
    }

    @Test func dateAfterAMultiWordDestinationStillSuggests() {
        let s = Self.suggest("#hit list tomorrow")
        #expect(s.active?.sigil == .date)
        #expect(s.active?.range == 10..<18)
        #expect(Self.names(s) == ["due:1:tomorrow"])
    }

    @Test func templateLineIsHandedToTheTemplateList() {
        let s = Self.suggest("/wee")
        #expect(s.active == EntryActiveToken(sigil: .template, range: 0..<4, query: "wee"))
        #expect(s.items.isEmpty)
        // A slash that is not the first character of the text is ordinary text.
        #expect(Self.suggest("a /wee").active == nil)
    }

    // MARK: pill-slot menus

    @Test func slotMenus() {
        let dest = EntrySuggester.suggestions(for: .destination, directory: F.directory, today: F.today, languages: F.languages, limit: 20)
        #expect(dest.count == 8)
        #expect(!dest.contains { $0.isCreate })
        let narrowed = EntrySuggester.suggestions(for: .destination, query: "hit", directory: F.directory, today: F.today, languages: F.languages)
        #expect(narrowed.map(\.title) == ["Hit list", "Hit parade"])
        let prio = EntrySuggester.suggestions(for: .priority, directory: F.directory, today: F.today, languages: F.languages)
        #expect(prio.map(\.pill) == [.priority(.low), .priority(.medium), .priority(.high), .priority(.urgent)])
        let eff = EntrySuggester.suggestions(for: .effort, directory: F.directory, today: F.today, languages: F.languages)
        #expect(eff.map(\.pill) == [.effort(.xs), .effort(.s), .effort(.m), .effort(.l), .effort(.xl)])
        let due = EntrySuggester.suggestions(for: .due, directory: F.directory, today: F.today, languages: F.languages)
        #expect(due.first?.pill == .due(F.today))
        #expect(due.contains { $0.pill == .due(F.today + 1) && $0.title == "tomorrow" })
        let labels = EntrySuggester.suggestions(for: .label, directory: F.directory, today: F.today, languages: F.languages)
        #expect(labels.map(\.title) == ["deep work", "Deep dive", "finance"])
    }

    // Accepting a suggestion is: remove its range, add its pill. The text edit must leave a
    // clean title.
    @Test func acceptingRemovesTheTokenText() {
        let text = "call mom #hit li and more"
        let s = Self.suggest(text, caret: 16)
        #expect(s.active?.range == 9..<16)
        let cut = EntryEdit.removing(s.active!.range, from: text)
        #expect(cut.text == "call mom and more")
        #expect(cut.caret == 9)
    }
}
