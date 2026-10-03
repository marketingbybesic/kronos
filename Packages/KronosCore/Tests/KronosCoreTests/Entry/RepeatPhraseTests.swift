import Testing
import Foundation
@testable import KronosCore

/// "every / svaki" in the entry grammar. Every row below is written by hand: the line, the
/// title that must remain, and the schedule it must read. Day 20000 is Friday 4 October 2024
/// (ISO weekday 5, day 4 of the month).
struct RepeatPhraseTests {
    static let today = 20000
    static let calendar = Calendar(identifier: .gregorian)

    static func parse(_ s: String) -> EntryParse {
        EntryParser.parse(s, directory: EntryFixture.directory, today: today, languages: ["en", "hr"],
                          calendar: calendar, readsRepeat: true)
    }

    struct Row {
        var input: String
        var title: String
        var phrase: RepeatPhrase?
        var due: Int? = nil
    }

    static let english: [Row] = [
        Row(input: "Water the plants every day", title: "Water the plants", phrase: RepeatPhrase(unit: .day)),
        Row(input: "Weekly review every week", title: "Weekly review", phrase: RepeatPhrase(unit: .week)),
        Row(input: "Pay rent every month", title: "Pay rent", phrase: RepeatPhrase(unit: .month)),
        Row(input: "Every day stretch", title: "stretch", phrase: RepeatPhrase(unit: .day)),
        Row(input: "Team sync every Monday", title: "Team sync", phrase: RepeatPhrase(unit: .week, weekday: 1)),
        Row(input: "Bins every thursday", title: "Bins", phrase: RepeatPhrase(unit: .week, weekday: 4)),
        Row(input: "Backup every 2 weeks", title: "Backup", phrase: RepeatPhrase(every: 2, unit: .week)),
        Row(input: "Haircut every six weeks", title: "Haircut", phrase: RepeatPhrase(every: 6, unit: .week)),
        Row(input: "Invoice every other month", title: "Invoice", phrase: RepeatPhrase(every: 2, unit: .month)),
        Row(input: "Vitamins every 3 days", title: "Vitamins", phrase: RepeatPhrase(every: 3, unit: .day)),
        // A date in the same line stays a date (the first occurrence).
        Row(input: "Report every week tomorrow", title: "Report", phrase: RepeatPhrase(unit: .week), due: 20001),
        Row(input: "Report every month #hit list", title: "Report", phrase: RepeatPhrase(unit: .month)),
        // Not a schedule: the words stay in the title.
        Row(input: "Every little thing", title: "Every little thing", phrase: nil),
        Row(input: "Read everything", title: "Read everything", phrase: nil),
        Row(input: "every", title: "every", phrase: nil),
        Row(input: "Call every 0 days", title: "Call every 0 days", phrase: nil),
        Row(input: "Call every 100 days", title: "Call every 100 days", phrase: nil),
    ]

    static let croatian: [Row] = [
        Row(input: "Zalij biljke svaki dan", title: "Zalij biljke", phrase: RepeatPhrase(unit: .day)),
        Row(input: "Pregled svaki tjedan", title: "Pregled", phrase: RepeatPhrase(unit: .week)),
        Row(input: "Plati najam svaki mjesec", title: "Plati najam", phrase: RepeatPhrase(unit: .month)),
        Row(input: "Sastanak svaki ponedjeljak", title: "Sastanak", phrase: RepeatPhrase(unit: .week, weekday: 1)),
        Row(input: "Smeće svaku srijedu", title: "Smeće", phrase: RepeatPhrase(unit: .week, weekday: 3)),
        Row(input: "Tržnica svake subote", title: "Tržnica", phrase: RepeatPhrase(unit: .week, weekday: 6)),
        Row(input: "Trening svaki četvrtak", title: "Trening", phrase: RepeatPhrase(unit: .week, weekday: 4)),
        Row(input: "Trening svaki cetvrtak", title: "Trening", phrase: RepeatPhrase(unit: .week, weekday: 4)),
        Row(input: "Misa svake nedjelje", title: "Misa", phrase: RepeatPhrase(unit: .week, weekday: 7)),
        Row(input: "Backup svaka 2 tjedna", title: "Backup", phrase: RepeatPhrase(every: 2, unit: .week)),
        Row(input: "Backup svaka dva tjedna", title: "Backup", phrase: RepeatPhrase(every: 2, unit: .week)),
        Row(input: "Vitamini svakih 5 dana", title: "Vitamini", phrase: RepeatPhrase(every: 5, unit: .day)),
        Row(input: "Račun svaka 3 mjeseca", title: "Račun", phrase: RepeatPhrase(every: 3, unit: .month)),
        Row(input: "Svakog dana šetnja", title: "šetnja", phrase: RepeatPhrase(unit: .day)),
        Row(input: "Izvještaj svaki tjedan sutra", title: "Izvještaj", phrase: RepeatPhrase(unit: .week), due: 20001),
        // Not a schedule.
        Row(input: "Svaki put provjeri", title: "Svaki put provjeri", phrase: nil),
        Row(input: "Kupi pet jabuka", title: "Kupi pet jabuka", phrase: nil),
    ]

    @Test(arguments: english + croatian)
    func reads(_ row: Row) {
        let p = Self.parse(row.input)
        #expect(p.title == row.title, "\(row.input)")
        #expect(p.repeatPhrase == row.phrase, "\(row.input)")
        if let due = row.due { #expect(p.dueDay == due, "\(row.input)") }
    }

    /// Without `readsRepeat` (every surface that cannot store a schedule) the words stay put.
    @Test func otherSurfacesKeepTheWords() {
        let p = EntryParser.parse("Pay rent every month", directory: EntryFixture.directory, today: Self.today,
                                  languages: ["en", "hr"], calendar: Self.calendar)
        #expect(p.title == "Pay rent every month")
        #expect(p.repeatPhrase == nil)
        let flat = QuickAddParser().parse("Zalij biljke svaki dan", projects: [], today: Self.today,
                                          languages: ["en", "hr"], calendar: Self.calendar)
        #expect(flat.title == "Zalij biljke svaki dan")
    }

    /// The token's range covers exactly the phrase, so the pill's x can cut it.
    @Test func tokenRange() {
        let p = Self.parse("Backup every 2 weeks now")
        let t = p.token(.repeats)
        #expect(t?.range == 7..<20)
    }

    /// A subtask line never reads a schedule: the words stay in its title.
    @Test func childEntryKeepsTheWords() {
        let r = ChildEntry.resolve(line: "Water it every day", pills: [.repeats(RepeatPhrase(unit: .day))],
                                   directory: EntryFixture.directory, today: Self.today, languages: ["en", "hr"])
        #expect(r.title == "Water it every day")
        #expect(r.repeatPhrase == nil)
    }

    struct RuleRow {
        var phrase: RepeatPhrase
        var firstDue: Int
        var wire: String
    }

    /// Day 20000 = Friday the 4th; 20003 = Monday the 7th.
    static let rules: [RuleRow] = [
        RuleRow(phrase: RepeatPhrase(unit: .day), firstDue: 20000, wire: "v1;daily;1;anchor=due"),
        RuleRow(phrase: RepeatPhrase(every: 3, unit: .day), firstDue: 20000, wire: "v1;daily;3;anchor=due"),
        RuleRow(phrase: RepeatPhrase(unit: .week), firstDue: 20000, wire: "v1;weekly;1;days=5;anchor=due"),
        RuleRow(phrase: RepeatPhrase(unit: .week), firstDue: 20003, wire: "v1;weekly;1;days=1;anchor=due"),
        RuleRow(phrase: RepeatPhrase(every: 2, unit: .week), firstDue: 20000, wire: "v1;weekly;2;days=5;anchor=due"),
        RuleRow(phrase: RepeatPhrase(unit: .week, weekday: 3), firstDue: 20005, wire: "v1;weekly;1;days=3;anchor=due"),
        RuleRow(phrase: RepeatPhrase(unit: .month), firstDue: 20000, wire: "v1;monthly;1;day=4;anchor=due"),
        RuleRow(phrase: RepeatPhrase(every: 3, unit: .month), firstDue: 20003, wire: "v1;monthly;3;day=7;anchor=due"),
    ]

    @Test(arguments: rules)
    func rule(_ row: RuleRow) {
        let wire = row.phrase.rule(firstDue: row.firstDue, calendar: Self.calendar).wireFormat
        #expect(wire == row.wire)
        #expect(RecurrenceRule.parse(wire) != nil)
    }

    /// With no date typed: today, or the next named weekday (today when it is that weekday).
    @Test func firstDue() {
        let c = Self.calendar
        #expect(RepeatPhrase(unit: .day).firstDue(today: 20000, calendar: c) == 20000)
        #expect(RepeatPhrase(unit: .month).firstDue(today: 20000, calendar: c) == 20000)
        #expect(RepeatPhrase(unit: .week, weekday: 5).firstDue(today: 20000, calendar: c) == 20000)
        #expect(RepeatPhrase(unit: .week, weekday: 1).firstDue(today: 20000, calendar: c) == 20003)
        #expect(RepeatPhrase(unit: .week, weekday: 4).firstDue(today: 20000, calendar: c) == 20006)
    }

    /// Clicking the pill lists the three plain schedules.
    @Test func slotMenu() {
        let items = EntrySuggester.suggestions(for: .repeats, directory: EntryFixture.directory, today: Self.today)
        #expect(items.map(\.pill) == [.repeats(RepeatPhrase(unit: .day)), .repeats(RepeatPhrase(unit: .week)),
                                      .repeats(RepeatPhrase(unit: .month))])
    }
}
