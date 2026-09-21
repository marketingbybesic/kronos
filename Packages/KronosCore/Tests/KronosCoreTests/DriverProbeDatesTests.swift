// An independent hand table for relative-date parsing. Offsets are days from Monday
// 2026-09-21, written by hand from a paper calendar.
import Foundation
import Testing
@testable import KronosCore

@Suite struct DriverProbeDatesTests {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Zagreb")!
        c.firstWeekday = 2
        return c
    }
    private var today: Int {
        var dc = DateComponents(); dc.year = 2026; dc.month = 9; dc.day = 21; dc.hour = 12
        return Day.from(cal.date(from: dc)!, calendar: cal)
    }

    /// (input, expected offset or nil, expected title or nil = do not check, languages)
    private static let rows: [(String, Int?, String?, [String])] = [
        // common real-world phrasing, including typos
        ("Call Alex tommorow", 1, "Call Alex", ["en", "hr"]),
        ("Platiti racun sutra", 1, "Platiti racun", ["en", "hr"]),
        ("Nazvati banku prekosutra", 2, "Nazvati banku", ["en", "hr"]),
        ("Izvjestaj sljedeci tjedan", 7, "Izvjestaj", ["en", "hr"]),
        ("Izvještaj sljedeći tjedan", 7, "Izvještaj", ["en", "hr"]),
        ("Izvjestaj iduci tjedan", 7, "Izvjestaj", ["en", "hr"]),
        ("Plan sljedeci mjesec", 30, "Plan", ["en", "hr"]),
        ("Plan idući mjesec", 30, "Plan", ["en", "hr"]),
        ("Report next week", 7, "Report", ["en", "hr"]),
        ("Plan next month", 30, "Plan", ["en", "hr"]),
        // inflected Croatian + prepositions
        ("Ponuda do petka", 4, "Ponuda", ["en", "hr"]),
        ("Sastanak u srijedu", 2, "Sastanak", ["en", "hr"]),
        ("Poslati za tjedan dana", 7, "Poslati", ["en", "hr"]),
        ("Poslati za 3 tjedna", 21, "Poslati", ["en", "hr"]),
        ("Poslati za pet dana", 5, "Poslati", ["en", "hr"]),
        ("Send in 2 weeks", 14, "Send", ["en", "hr"]),
        ("Send day after tomorrow", 2, "Send", ["en", "hr"]),
        ("Zatvoriti krajem mjeseca", 9, "Zatvoriti", ["en", "hr"]),
        ("Close end of month", 9, "Close", ["en", "hr"]),
        ("Pospremiti vikend", 5, "Pospremiti", ["en", "hr"]),
        ("Invoice by friday", 4, "Invoice", ["en", "hr"]),
        ("Invoice tmrw", 1, "Invoice", ["en", "hr"]),
        // a system language the code has no hand table for
        ("Anrufen morgen", 1, "Anrufen", ["de"]),
        ("Anrufen übermorgen", 2, "Anrufen", ["de"]),
        // NEGATIVES: no date, title untouched
        ("Kupiti pet jabuka", nil, "Kupiti pet jabuka", ["en", "hr"]),
        ("Tomislav zvati", nil, "Tomislav zvati", ["en", "hr"]),
        ("Release 1.5 notes", nil, "Release 1.5 notes", ["en", "hr"]),
        ("Jutra su hladna", nil, "Jutra su hladna", ["en", "hr"]),
        ("Monthly report draft", nil, "Monthly report draft", ["en", "hr"]),
        ("Next steps for Acme", nil, "Next steps for Acme", ["en", "hr"]),
        ("Weekly sync notes", nil, "Weekly sync notes", ["en", "hr"]),
        ("Do not forget milk", nil, "Do not forget milk", ["en", "hr"]),
        ("Na stolu je mapa", nil, "Na stolu je mapa", ["en", "hr"]),
        ("Sve je u redu", nil, "Sve je u redu", ["en", "hr"]),
        ("Buy a sub sandwich", nil, "Buy a sub sandwich", ["en", "hr"]),
        ("Pet shop visit", nil, "Pet shop visit", ["en", "hr"]),
        ("Morgen Stanley call", nil, "Morgen Stanley call", ["en", "hr"]),
        // follow-up: bare English 3-letter weekday abbreviations mid-title stay literal
        ("Buy sun cream", nil, "Buy sun cream", ["en", "hr"]),
        ("He sat on the report", nil, "He sat on the report", ["en", "hr"]),
        ("Wed the two configs", nil, "Wed the two configs", ["en", "hr"]),
        ("Fix the mon dashboard", nil, "Fix the mon dashboard", ["en", "hr"]),
        ("Call Alex fri", 4, "Call Alex", ["en", "hr"]),
        ("Invoice by sat", 5, "Invoice", ["en", "hr"]),
        ("Report next wed", 2, "Report", ["en", "hr"]),
        ("Buy cream sun", 6, "Buy cream", ["en", "hr"]),
    ]

    @Test func independentTable() {
        var failures: [String] = []
        for (input, offset, title, langs) in Self.rows {
            let p = QuickAddParser().parse(input, projects: [], today: today, languages: langs, calendar: cal)
            let got = p.dueDay.map { $0 - today }
            if got != offset {
                failures.append("DATE  \"\(input)\" expected \(String(describing: offset)) got \(String(describing: got)) title=\"\(p.title)\"")
            } else if let title, p.title != title {
                failures.append("TITLE \"\(input)\" expected \"\(title)\" got \"\(p.title)\"")
            }
        }
        print("DRIVER PROBE rows=\(Self.rows.count) failures=\(failures.count)")
        failures.forEach { print("  " + $0) }
        #expect(failures.isEmpty)
    }

    @Test func vocabularyIsCachedNotRebuiltPerKeystroke() {
        let clock = ContinuousClock()
        _ = QuickAddParser().parse("warm up sutra", projects: [], today: today)
        let elapsed = clock.measure {
            for _ in 0..<200 { _ = QuickAddParser().parse("Call Alex tommorow", projects: [], today: today) }
        }
        let perParseMs = Double(elapsed.components.attoseconds) / 1e15 / 200 + Double(elapsed.components.seconds) * 1000 / 200
        print("DRIVER PROBE perParseMs=\(String(format: "%.3f", perParseMs))")
        #expect(perParseMs < 2.0, "quick add re-parses on every keystroke; must stay far below a frame")
    }
}
