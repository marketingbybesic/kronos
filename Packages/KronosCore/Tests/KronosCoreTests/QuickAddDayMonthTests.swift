import Testing
import Foundation
@testable import KronosCore

/// The quick add legend promises "25.9."; this is the proof the parser keeps that promise.
struct QuickAddDayMonthTests {
    private let cal = Calendar.current
    private func day(_ y: Int, _ m: Int, _ d: Int) -> Int {
        Day.from(cal.date(from: DateComponents(year: y, month: m, day: d))!, calendar: cal)
    }

    @Test func yearlessDateIsNextOccurrence() {
        let today = day(2026, 9, 20)
        #expect(QuickAddParser.parseDayMonth("25.9.", today: today) == day(2026, 9, 25))
        #expect(QuickAddParser.parseDayMonth("20.9.", today: today) == today)
        #expect(QuickAddParser.parseDayMonth("1.3.", today: today) == day(2027, 3, 1))
    }

    @Test func explicitYear() {
        #expect(QuickAddParser.parseDayMonth("5.1.2027", today: day(2026, 9, 20)) == day(2027, 1, 5))
        #expect(QuickAddParser.parseDayMonth("5.1.2027.", today: day(2026, 9, 20)) == day(2027, 1, 5))
    }

    @Test func versionNumbersAndNonsenseStayInTheTitle() {
        let today = day(2026, 9, 20)
        for token in ["1.5", "v1.5.", "31.2.", "32.1.", "5.13.", "1.5.26", "..", "12."] {
            #expect(QuickAddParser.parseDayMonth(token, today: today) == nil, "\(token)")
        }
    }

    @Test func parserUsesItAndKeepsTheTitleClean() {
        let today = day(2026, 9, 20)
        let parsed = QuickAddParser().parse("Send offer 25.9. for release 1.5", projects: [], today: today)
        #expect(parsed.dueDay == day(2026, 9, 25))
        #expect(parsed.title == "Send offer for release 1.5")
    }
}
