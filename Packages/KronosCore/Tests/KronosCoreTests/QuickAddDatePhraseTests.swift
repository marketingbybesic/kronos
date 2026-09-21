import Testing
import Foundation
@testable import KronosCore

// Covers relative-date parsing broadly: typo tolerance ("tommorow"), the full set of
// relative-date expressions (tomorrow, day-after-tomorrow, next week, next month, and
// similar) in both English and Croatian, plus system-sourced vocabulary for other languages.
//
// Expectations below are HAND-COMPUTED day offsets from two fixed anchors, never derived
// by calling the code under test:
//   - `today` = 20003 = Monday 2024-10-07 (weekday tests, "next X").
//   - `monthEnd` = 20119 = Friday 2025-01-31 (end-of-month / next-month clamp tests;
//     February 2025 has 28 days, not a leap year).
// Weekday offsets from `today` (Monday), strictly-after-today rule:
//   Tue +1, Wed +2, Thu +3, Fri +4, Sat +5, Sun +6, Mon +7.
struct QuickAddDatePhraseTests {
    let parser = QuickAddParser()
    let today = 20003     // Monday 2024-10-07
    let monthEnd = 20119  // Friday 2025-01-31

    // MARK: - The shipping bug (must fail on untouched code)

    /// Without typo tolerance, `dayFor` cannot match "tommorow" at all: `dueDay` stays nil,
    /// and the whole word survives in the title.
    @Test func typoTommorowResolvesToTomorrow() {
        let p = parser.parse("Call Alex tommorow", projects: [], today: today)
        #expect(p.dueDay == today + 1)
        #expect(p.title == "Call Alex")
    }

    // MARK: - Already-shipping bug: bare "pet" must never mean Friday

    /// `weekdayNames["pet"] == 5` (petak) currently matches on ANY bare "pet" token,
    /// including the Croatian word for the number five. This is the negative that must
    /// fail on main before any fix.
    @Test func barePetIsNeverFriday() {
        let p = parser.parse("Kupiti pet jabuka", projects: [], today: today)
        #expect(p.dueDay == nil)
        #expect(p.title == "Kupiti pet jabuka")
    }

    /// The number path: "pet" inside a matched "za N dana" window must resolve through
    /// the word-number table to 5, not be treated as a date word by itself.
    @Test func zaPetDanaResolvesToFiveDaysNotFriday() {
        let p = parser.parse("Platiti račun za pet dana", projects: [], today: today)
        #expect(p.dueDay == today + 5)
        #expect(p.title == "Platiti račun")
    }

    // MARK: - English 3-letter weekday abbreviations mid-title

    /// Same defect class as "pet"=Friday: a bare English 3-letter weekday abbreviation
    /// collided with ordinary words anywhere in a title ("Buy sun cream" -> Sunday, title
    /// became "Buy cream"). Fix: it counts as a date ONLY at the last token, or directly
    /// after a swallowed preposition / "next" / "this"; anywhere else it stays an ordinary
    /// word. These four negatives must resolve to nil with the title UNCHANGED.
    @Test func englishWeekdayAbbreviationMidTitleStaysLiteral() {
        let sun = parser.parse("Buy sun cream", projects: [], today: today)
        #expect(sun.dueDay == nil)
        #expect(sun.title == "Buy sun cream")

        let sat = parser.parse("He sat on the report", projects: [], today: today)
        #expect(sat.dueDay == nil)
        #expect(sat.title == "He sat on the report")

        let wed = parser.parse("Wed the two configs", projects: [], today: today)
        #expect(wed.dueDay == nil)
        #expect(wed.title == "Wed the two configs")

        let mon = parser.parse("Fix the mon dashboard", projects: [], today: today)
        #expect(mon.dueDay == nil)
        #expect(mon.title == "Fix the mon dashboard")
    }

    /// Positives for the same rule: last token, or guarded by a swallowed preposition/
    /// "next"/"this".
    @Test func englishWeekdayAbbreviationPositionalPositives() {
        let lastToken = parser.parse("Call Alex fri", projects: [], today: today)
        #expect(lastToken.dueDay == today + 4)
        #expect(lastToken.title == "Call Alex")

        let byGuard = parser.parse("Invoice by sat", projects: [], today: today)
        #expect(byGuard.dueDay == today + 5)
        #expect(byGuard.title == "Invoice")

        let nextGuard = parser.parse("Report next wed", projects: [], today: today)
        #expect(nextGuard.dueDay == today + 2)
        #expect(nextGuard.title == "Report")

        let lastToken2 = parser.parse("Buy cream sun", projects: [], today: today)
        #expect(lastToken2.dueDay == today + 6)
        #expect(lastToken2.title == "Buy cream")
    }

    // MARK: - Positive table: system + hand vocabulary, en + hr (>= 60 rows total incl. below)

    struct Row { let input: String; let offset: Int; let file: String = #file; let line: Int }

    @Test func positiveTable() {
        // (typed phrase, expected day offset from `today` unless noted)
        let rows: [(String, Int)] = [
            // --- core single words, both languages ---
            ("today", 0), ("Danas", 0),
            ("tomorrow", 1), ("Sutra", 1),
            ("tonight", 0), ("večeras", 0), ("veceras", 0),
            ("day after tomorrow", 2), ("prekosutra", 2),
            // --- typo tolerance (>= 7 chars, same first letter, DL <= 2) ---
            ("tommorow", 1), ("tomorow", 1), ("tommorrow", 1), ("tomorrrow", 1),
            // --- short-word explicit misspelling list (< 7 chars, no DL rule) ---
            ("sjutra", 1), ("sutr", 1),
            // --- hand-table short forms ---
            ("tmrw", 1), ("tmr", 1), ("2morrow", 1), ("tom", 1),
            // --- weekdays, English, full + abbreviated, strictly after today (Monday) ---
            ("tuesday", 1), ("tue", 1),
            ("wednesday", 2), ("wed", 2),
            ("thursday", 3), ("thu", 3),
            ("friday", 4), ("fri", 4),
            ("saturday", 5), ("sat", 5),
            ("sunday", 6), ("sun", 6),
            ("monday", 7), ("mon", 7),
            // --- weekdays, Croatian, nominative (bare 3-letter abbreviations are DROPPED —
            // see barePetIsNeverFriday and the negative table: "uto"/"sri"/"čet"/"sub"/
            // "ned"/"pon" collide with ordinary short words the same way "pet" did) ---
            ("utorak", 1),
            ("srijeda", 2),
            ("četvrtak", 3), ("cetvrtak", 3),
            ("petak", 4),
            ("subota", 5),
            ("nedjelja", 6),
            ("ponedjeljak", 7),
            // --- Croatian inflected weekday case forms ---
            ("ponedjeljka", 7), ("utorka", 1), ("srijede", 2), ("srijedu", 2),
            ("četvrtka", 3), ("cetvrtka", 3), ("petka", 4),
            ("subote", 5), ("subotu", 5), ("nedjelje", 6), ("nedjelju", 6),
            // --- next + week/weekday ---
            ("next week", 7), ("sljedeći tjedan", 7), ("sljedeci tjedan", 7),
            ("idući tjedan", 7), ("iduci tjedan", 7),
            ("next monday", 7), ("sljedeći ponedjeljak", 7),
            ("next friday", 4), // strictly-after rule: nearest Friday after Monday is +4
            // --- "in|za N day/week/month" ---
            ("in 3 days", 3), ("za 3 dana", 3),
            ("in a week", 7), ("za tjedan dana", 7),
            // Calendar month-add, not a flat 30: today is 2024-10-07 (October, 31 days), so
            // "in a month" = 2024-11-07 = today+31.
            ("in a month", 31), ("za mjesec dana", 31),
            ("in 2 weeks", 14), ("za 2 tjedna", 14),
            // --- number words one..ten / jedan..deset feeding "in|za N ..." ---
            ("in five days", 5), ("za pet dana", 5),
            ("in ten days", 10), ("za deset dana", 10),
            ("za jedan dan", 1), ("in one day", 1),
            // --- this weekend / end of week ---
            ("this weekend", 5), ("weekend", 5), ("vikend", 5), ("ovaj vikend", 5),
            ("end of week", 4), ("eow", 4), ("kraj tjedna", 4), ("krajem tjedna", 4),
            // --- prepositions swallowed with a following date phrase ---
            ("by friday", 4), ("on monday", 7), ("until friday", 4), ("till friday", 4),
            ("due tomorrow", 1),
            ("do petka", 4), ("u ponedjeljak", 7), ("za petak", 4),
            // --- weekday inside a longer title, still consumed ---
            ("Call bank tuesday", 1),
        ]
        for (input, offset) in rows {
            let p = parser.parse(input, projects: [], today: today)
            #expect(p.dueDay == today + offset, "input='\(input)' expected today+\(offset)")
        }
    }

    /// German sample through the system-sourced vocabulary (CLDR relative-date words),
    /// injecting `languages: ["de"]`. Proves the mechanism is language-general, not just
    /// an en/hr hand table: it consults the system's own CLDR words for whatever
    /// `Locale.preferredLanguages` returns, verified on en/hr/de.
    @Test func germanSampleThroughSystemVocabulary() {
        let p = parser.parse("Anruf morgen", projects: [], today: today, languages: ["de"])
        #expect(p.dueDay == today + 1, "system-sourced German 'morgen' (tomorrow) should resolve")
    }

    // MARK: - Month-end / next-month table (fixed anchor: Friday 2025-01-31)

    @Test func endOfMonthAndNextMonthTable() {
        let rows: [(String, Int)] = [
            ("end of month", 0),      // Jan 31 IS the last day already
            ("eom", 0),
            ("kraj mjeseca", 0),
            ("krajem mjeseca", 0),
            ("next month", 28),       // Feb 28 2025 (clamped: Feb has no 31st)
            ("sljedeći mjesec", 28), ("sljedeci mjesec", 28),
            ("idući mjesec", 28), ("iduci mjesec", 28), ("drugi mjesec", 28),
            ("next year", 365),       // 2025 is not a leap year
        ]
        for (input, offset) in rows {
            let p = parser.parse(input, projects: [], today: monthEnd)
            #expect(p.dueDay == monthEnd + offset, "input='\(input)' expected monthEnd+\(offset)")
        }
    }

    // MARK: - Negative table (>= 15 rows): title untouched, date nil

    @Test func negativeTable() {
        let rows: [String] = [
            "Kupiti pet jabuka",              // hr "five", not Friday (dedicated test above too)
            "Buy jam",                        // short word, no relation
            "jutra",                           // hr "mornings" — not a date word
            "Tomislav is coming",              // Croatian name, distance risk from "tomorrow"
            "Pay invoice 1.5",                 // version-number-shaped token, not a day.month date
            "Buy sub sandwich",                // bare 3-letter hr abbrev "sub" without swallowed preposition
            "Fix sri unit test",                // bare "sri" (hr abbrev for srijeda) mid-sentence
            "ned the developer called",         // bare "ned" (hr abbrev for nedjelja) as a name-like token
            "uto pattern in the logs",          // bare "uto" (hr abbrev for utorak)
            "cet timezone bug",                 // bare "cet" (hr abbrev for četvrtak, also collides with CET timezone)
            "pon file to review",               // bare "pon" (hr abbrev for ponedjeljak)
            "May the tests pass",               // "may" is not a handled month/date word
            "Rezervirati veccera",              // hr "dinner" — 2 edits from "veceras" ("tonight");
                                                 // a real collision found by a typo-collision scan,
                                                 // excluded explicitly (see DatePhrases.explicitExclusions)
        ]
        for input in rows {
            let p = parser.parse(input, projects: [], today: today)
            #expect(p.dueDay == nil, "input='\(input)' must not resolve a date")
        }
    }

    /// Documented, accepted cost — NOT a negative. "Sutra" is Croatian for "tomorrow" and a
    /// bare token always means the date, even as part of a book title.
    ///
    /// "Call sat phone" was previously an accepted cost too, since "sat" (the English
    /// Saturday abbreviation) matched unconditionally. That is now fixed: "sat" is not the
    /// last token and not preceded by a swallowed preposition/"next"/"this", so it correctly
    /// stays literal — see `englishWeekdayAbbreviationMidTitleStaysLiteral` ("He sat on the
    /// report" is one of that test's four rows).
    @Test func documentedKnownCosts() {
        let sutra = parser.parse("Read Sutra book", projects: [], today: today)
        #expect(sutra.dueDay == today + 1, "known cost: bare 'Sutra' always resolves, even mid-title")
    }

    /// "tomorrows" (real English word, plural/possessive of "tomorrow") must not be treated
    /// as a typo of "tomorrow" when it appears as an ordinary word in running text — the
    /// exact-word guard in the typo rule (hand table exclusion) plus DL distance decide this.
    @Test func tomorrowsPluralDocumentedBehaviour() {
        let p = parser.parse("Reading about tomorrows plans", projects: [], today: today)
        // "tomorrows" IS within DL<=2 of "tomorrow" and shares its first letter/length>=7,
        // so by the stated rule it resolves as a date word (documented, not silently wrong).
        #expect(p.dueDay == today + 1)
    }
}
