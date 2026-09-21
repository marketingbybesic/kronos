import Testing
import Foundation
@testable import KronosCore

struct QuickAddParserTests {
    let parser = QuickAddParser()
    let today = 20000

    @Test func fullGrammar() {
        let p = parser.parse("Nazvati Alexa sutra !!! #acme",
                             projects: ["Acme"], today: today)
        #expect(p.title == "Nazvati Alexa")
        #expect(p.projectName == "Acme")
        #expect(p.priority == .high)
        #expect(p.dueDay == today + 1)
    }

    @Test func labelToken() {
        let p = parser.parse("Call bank @finance", projects: [], today: today)
        #expect(p.title == "Call bank")
        #expect(p.labelName == "finance")
    }

    @Test func unresolvedProjectStays() {
        let p = parser.parse("Fix bike #nepostojeci", projects: ["Acme"], today: today)
        #expect(p.unresolvedProjectToken == "#nepostojeci")
        #expect(p.title.contains("#nepostojeci"))
        #expect(p.projectName == nil)
    }

    @Test func diacriticDashMatch() {
        let p = parser.parse("Task #acme-skola", projects: ["Acme škola"], today: today)
        #expect(p.projectName == "Acme škola")
    }

    @Test func priorityFiveBangsIsNotAToken() {
        let p = parser.parse("Task !!!!!", projects: [], today: today)
        #expect(p.priority == .none)
        #expect(p.title == "Task !!!!!")
    }

    @Test func isoDateToken() {
        let p = parser.parse("Pay rent 2030-01-15", projects: [], today: today)
        #expect(p.dueDay == Day.parseISO("2030-01-15"))
        #expect(p.title == "Pay rent")
    }

    @Test func secondProjectTokenStaysLiteral() {
        let p = parser.parse("Task #acme #acme", projects: ["Acme"], today: today)
        #expect(p.projectName == "Acme")
        #expect(p.title == "Task #acme")
    }

    // The unresolved-project chip must actually rewrite the token when clicked/created so the
    // task gets that project on submit — otherwise picking a suggested project visibly does
    // nothing to the fields.
    @Test func rewriteProjectTokenReplacesUnresolvedToken() {
        let p = parser.parse("Fix bike #nepostojeci", projects: ["Acme"], today: today)
        #expect(p.unresolvedProjectToken == "#nepostojeci")
        let rewritten = QuickAddParser.rewriteProjectToken(in: "Fix bike #nepostojeci",
                                                            unresolvedToken: p.unresolvedProjectToken!,
                                                            resolvedProjectName: "Acme")
        #expect(rewritten == "Fix bike #Acme")
        // Re-parsing the rewritten text now resolves the project for real.
        let reparsed = parser.parse(rewritten, projects: ["Acme"], today: today)
        #expect(reparsed.projectName == "Acme")
        #expect(reparsed.unresolvedProjectToken == nil)
        #expect(reparsed.title == "Fix bike")
    }

    @Test func rewriteProjectTokenEncodesSpacesAsDashes() {
        let rewritten = QuickAddParser.rewriteProjectToken(in: "Task #nepostojeci",
                                                            unresolvedToken: "#nepostojeci",
                                                            resolvedProjectName: "Acme škola")
        #expect(rewritten == "Task #Acme-škola")
        let reparsed = parser.parse(rewritten, projects: ["Acme škola"], today: today)
        #expect(reparsed.projectName == "Acme škola")
    }

    @Test func rewriteProjectTokenLeavesInputUnchangedWhenTokenMissing() {
        let unchanged = QuickAddParser.rewriteProjectToken(in: "Task title",
                                                            unresolvedToken: "#missing",
                                                            resolvedProjectName: "Acme")
        #expect(unchanged == "Task title")
    }

    // The `*` effort alias must survive composition with TaskOutline, since subtasks can come
    // from the same field — `QuickAddCreate` (Kronos/Shared/QuickAddCreate.swift) runs exactly
    // this: `TaskOutline.parse` first, then `QuickAddParser.parse` on each item's task LINE
    // only, never on the subtask titles.
    @Test func effortAliasSurvivesTaskOutlineComposition() {
        let items = TaskOutline.parse("Prepare the offer #acme *m sutra\n\tfind the template\n\tfill in prices")
        #expect(items.count == 1)
        let item = items[0]
        #expect(item.subtasks == ["find the template", "fill in prices"])
        let p = parser.parse(item.line, projects: ["Acme"], today: today)
        #expect(p.title == "Prepare the offer")
        #expect(p.projectName == "Acme")
        #expect(p.effort == KEffort.m)
        #expect(p.dueDay == today + 1)
        // Subtask titles are plain text, never run through QuickAddParser: a size/date-looking
        // word in one stays literal, matching QuickAddCreate's own behaviour.
        #expect(item.subtasks.allSatisfy { !$0.contains("*") })
    }
}

// Natural relative dates, in both English and Croatian, following the system language.
// `today` (20000) is a fixed Friday (2024-10-04) so every weekday offset here is hand-verified
// against a real calendar, not against the code under test.
struct QuickAddNaturalDateTests {
    let parser = QuickAddParser()
    let today = 20000

    @Test func todayTonightTomorrowDanasSutra() {
        #expect(parser.parse("Call today", projects: [], today: today).dueDay == today)
        #expect(parser.parse("Call tonight", projects: [], today: today).dueDay == today)
        #expect(parser.parse("Nazovi danas", projects: [], today: today).dueDay == today)
        #expect(parser.parse("Call tomorrow", projects: [], today: today).dueDay == today + 1)
        #expect(parser.parse("Nazovi sutra", projects: [], today: today).dueDay == today + 1)
        #expect(parser.parse("Nazovi prekosutra", projects: [], today: today).dueDay == today + 2)
    }

    @Test func weekdayNamesEnglishAndCroatianRegardlessOfAppLanguage() {
        // today is a Friday: "monday" (bare) is the NEXT one, 3 days out; "friday" (same weekday
        // as today) means next week's, 7 days out — never "today itself" for a named weekday.
        #expect(parser.parse("Call mon", projects: [], today: today).dueDay == today + 3)
        #expect(parser.parse("Call Monday", projects: [], today: today).dueDay == today + 3)
        #expect(parser.parse("Nazovi ponedjeljak", projects: [], today: today).dueDay == today + 3)
        #expect(parser.parse("Call fri", projects: [], today: today).dueDay == today + 7)
        #expect(parser.parse("Call sunday", projects: [], today: today).dueDay == today + 2)
        #expect(parser.parse("Nazovi nedjelja", projects: [], today: today).dueDay == today + 2)
        // Bare 3-letter Croatian weekday abbreviations ("pon", "uto", "sri", "cet"/"čet",
        // "pet", "sub", "ned") are DROPPED from `weekdayNames` — "pet" collided with the
        // Croatian word for "five" and turned "Kupiti pet jabuka" into a Friday task;
        // "pon"/"ned"/etc. carry the same risk as ordinary short words or name fragments. See
        // QuickAddDatePhraseTests for the full positive/negative tables. English 3-letter
        // forms ("mon"/"fri"/"sun" above) are kept: they don't collide with common English
        // words the way the Croatian ones do.
        #expect(parser.parse("Nazovi pon", projects: [], today: today).dueDay == nil)
        #expect(parser.parse("Nazovi ned", projects: [], today: today).dueDay == nil)
    }

    @Test func nextWeekAndNextWeekday() {
        #expect(parser.parse("Plan next week", projects: [], today: today).dueDay == today + 7)
        #expect(parser.parse("Plan sljedeći tjedan", projects: [], today: today).dueDay == today + 7)
        #expect(parser.parse("Call next monday", projects: [], today: today).dueDay == today + 3)
        #expect(parser.parse("Call next friday", projects: [], today: today).dueDay == today + 7)
    }

    @Test func inNDaysAndZaNDana() {
        #expect(parser.parse("Follow up in 3 days", projects: [], today: today).dueDay == today + 3)
        #expect(parser.parse("Follow up in 1 day", projects: [], today: today).dueDay == today + 1)
        #expect(parser.parse("Nazovi za 5 dana", projects: [], today: today).dueDay == today + 5)
    }

    @Test func europeanShortDatesStillWork() {
        #expect(parser.parse("Pay 25.9.", projects: [], today: today).dueDay
                == QuickAddParser.parseDayMonth("25.9.", today: today))
        #expect(parser.parse("Pay 25.9.2026", projects: [], today: today).dueDay
                == QuickAddParser.parseDayMonth("25.9.2026", today: today))
        #expect(parser.parse("Pay 2026-12-01", projects: [], today: today).dueDay
                == Day.parseISO("2026-12-01"))
    }

    // The phrase words are consumed from the title, and a version-number-like token stays inert.
    @Test func matchedPhraseIsRemovedFromTitleAndUnmatchedWordsStay() {
        let p = parser.parse("Follow up in 3 days please", projects: [], today: today)
        #expect(p.title == "Follow up please")
        let unrelated = parser.parse("Ship v1.5 next", projects: [], today: today)
        #expect(unrelated.dueDay == nil)
        #expect(unrelated.title == "Ship v1.5 next")
    }
}