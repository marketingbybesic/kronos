// Covers the `~xs ~s ~m ~l ~xl` effort token, a first-class attribute alongside deadline and
// priority, and `*xs *s *m *l *xl` as the primary alias (`~` needs a dead-key chord on a
// Croatian Mac keyboard; `*` is a plain Shift-8).
//
// The trap this token walks into: real task titles can contain `~/Downloads`. A prefix match
// on "~" would eat the path out of the title and silently corrupt the task, so the token is
// matched against the WHOLE word. Same care applies to `*`: a title like "5*3 plan" must stay
// a title.

import Testing
import Foundation
@testable import KronosCore

struct QuickAddEffortTests {

    private let parser = QuickAddParser()
    private let today = Day.today()

    @Test func quickAddParsesEffortToken() throws {
        let sizes: [(String, KEffort)] = [
            ("~xs", .xs), ("~s", .s), ("~m", .m), ("~l", .l), ("~xl", .xl)
        ]
        for (token, expected) in sizes {
            let out = parser.parse("Napisati ponudu \(token)", projects: [], today: today)
            #expect(out.effort == expected, "\(token) should parse as \(expected)")
            // The token is stripped from the title, like every other token.
            #expect(out.title == "Napisati ponudu")
        }

        // Case-insensitive, same as the other tokens.
        let upper = parser.parse("Pregledati ugovor ~XL", projects: [], today: today)
        #expect(upper.effort == KEffort.xl)
        #expect(upper.title == "Pregledati ugovor")

        // Absent means nil, NOT KEffort.none: a caller must be able to tell
        // "sized as none" from "said nothing about size" and leave an
        // existing effort alone in the second case.
        let silent = parser.parse("Bez veličine", projects: [], today: today)
        #expect(silent.effort == nil)
    }

    @Test func quickAddParsesAsteriskEffortAlias() throws {
        let sizes: [(String, KEffort)] = [
            ("*xs", .xs), ("*s", .s), ("*m", .m), ("*l", .l), ("*xl", .xl)
        ]
        for (token, expected) in sizes {
            let out = parser.parse("Napisati ponudu \(token)", projects: [], today: today)
            #expect(out.effort == expected, "\(token) should parse as \(expected)")
            #expect(out.title == "Napisati ponudu")
        }

        // Case-insensitive, same as `~`.
        let upper = parser.parse("Pregledati ugovor *XL", projects: [], today: today)
        #expect(upper.effort == KEffort.xl)
        #expect(upper.title == "Pregledati ugovor")

        // The exact title from the brief: a bare arithmetic-looking title must
        // survive untouched — "5*3" does not START with `*`, so it is never a token.
        let arithmetic = parser.parse("5*3 plan", projects: [], today: today)
        #expect(arithmetic.effort == nil)
        #expect(arithmetic.title == "5*3 plan")

        // A bare `*` is the star-count small-effort token (see quickAddParsesStarCountEffort
        // below) — unlike a bare tilde, which is inert.
        let bare = parser.parse("Samo * zvjezdica", projects: [], today: today)
        #expect(bare.effort == KEffort.s)
        #expect(bare.title == "Samo zvjezdica")

        // An asterisk inside a word is not a token either.
        let infix = parser.parse("Usporedi a*b", projects: [], today: today)
        #expect(infix.effort == nil)
        #expect(infix.title == "Usporedi a*b")

        // `*` and `~` still coexist: the last one typed wins, same as two `~` tokens.
        let mixed = parser.parse("Revizija ~s *l", projects: [], today: today)
        #expect(mixed.effort == KEffort.l)
        #expect(mixed.title == "Revizija ~s")
    }

    @Test func quickAddEffortTokenDoesNotEatTildeInTitle() throws {
        // Real task titles can contain paths. `~/Downloads` must survive
        // verbatim, and the trailing `~m` must still be read as the size.
        let out = parser.parse("Kopirati videa iz ~/Downloads ~m", projects: [], today: today)
        #expect(out.effort == KEffort.m)
        #expect(out.title == "Kopirati videa iz ~/Downloads")

        // A tilde inside a word is not a token either.
        let infix = parser.parse("Usporedi a~b", projects: [], today: today)
        #expect(infix.effort == nil)
        #expect(infix.title == "Usporedi a~b")

        // A bare tilde has no size after it.
        let bare = parser.parse("Samo ~ tilda", projects: [], today: today)
        #expect(bare.effort == nil)
        #expect(bare.title == "Samo ~ tilda")

        // A tilde followed by something that is not a size stays literal.
        let unknown = parser.parse("Veličina ~xxl", projects: [], today: today)
        #expect(unknown.effort == nil)
        #expect(unknown.title == "Veličina ~xxl")

        // A path with no size token at all is untouched.
        let pathOnly = parser.parse("Backup ~/Downloads/kronos", projects: [], today: today)
        #expect(pathOnly.effort == nil)
        #expect(pathOnly.title == "Backup ~/Downloads/kronos")
    }

    @Test func lastEffortTokenWins() throws {
        // A user correcting themselves types the new size after the old one.
        let out = parser.parse("Revizija ~s ~l", projects: [], today: today)
        #expect(out.effort == KEffort.l)
        // Only ONE token is consumed; the earlier one stays as literal text,
        // matching how the other token kinds behave.
        #expect(out.title == "Revizija ~s")
    }

    @Test func effortTokenCoexistsWithEveryOtherToken() throws {
        let out = parser.parse("Poslati ponudu #acme @hitno !!! sutra ~l",
                               projects: ["Acme"], today: today)
        #expect(out.effort == KEffort.l)
        #expect(out.projectName == "Acme")
        #expect(out.labelName == "hitno")
        #expect(out.priority == KPriority.high)
        #expect(out.dueDay == today + 1)
        #expect(out.title == "Poslati ponudu")
    }

    // A run of 1-3 bare `*` characters is its own effort token, mirroring how `!`..`!!!!`
    // already works for priority. The token must be the WHOLE token (nothing else in it) —
    // see the rule comment above the parser loop for exactly what that excludes.
    @Test func quickAddParsesStarCountEffort() throws {
        let table: [(String, KEffort)] = [("*", .s), ("**", .m), ("***", .l)]
        for (token, expected) in table {
            let out = parser.parse("Napisati ponudu \(token)", projects: [], today: today)
            #expect(out.effort == expected, "\(token) should parse as \(expected)")
            #expect(out.title == "Napisati ponudu")
        }

        // 4+ stars is not a token, same shape as 5 `!`.
        let tooMany = parser.parse("Task ****", projects: [], today: today)
        #expect(tooMany.effort == nil)
        #expect(tooMany.title == "Task ****")

        // Arithmetic survives: "5*3" is one token containing digits, never matches the
        // all-stars rule (its first character is "5", not "*", so it fails BOTH forms).
        let arithmetic = parser.parse("5*3 plan", projects: [], today: today)
        #expect(arithmetic.effort == nil)
        #expect(arithmetic.title == "5*3 plan")

        // A star fused to a letter is not an all-stars token either.
        let infix = parser.parse("Usporedi a*b", projects: [], today: today)
        #expect(infix.effort == nil)
        #expect(infix.title == "Usporedi a*b")

        // "a * b": deliberate decision (documented in the parser) — a lone `*` standing as its
        // OWN whitespace-separated token IS the star-count token (small), even between two
        // plain words. This is not the same shape as "5*3" or "a*b", where the star is fused
        // to other characters in one token.
        let loneBetweenWords = parser.parse("a * b", projects: [], today: today)
        #expect(loneBetweenWords.effort == KEffort.s)
        #expect(loneBetweenWords.title == "a b")

        // Composition with TaskOutline (QuickAddCreate's real call shape): the star-count form
        // survives being run through TaskOutline.parse first, exactly like the letter forms.
        let items = TaskOutline.parse("Prepare the offer #acme ** sutra\n\tfind the template")
        #expect(items.count == 1)
        let p = parser.parse(items[0].line, projects: ["Acme"], today: today)
        #expect(p.effort == KEffort.m)
        #expect(p.projectName == "Acme")
        #expect(p.dueDay == today + 1)
        #expect(p.title == "Prepare the offer")
    }

    // Star-count vs letter-suffix: whichever form appears LAST in the line wins, exactly like
    // two same-form tokens already do (`lastEffortTokenWins` above) — "last one wins" is
    // positional across both forms, not "star-count always wins".
    @Test func starCountAndLetterFormLastOneWinsIsPositional() throws {
        let starThenLetter = parser.parse("Revizija ** ~l", projects: [], today: today)
        #expect(starThenLetter.effort == KEffort.l)
        #expect(starThenLetter.title == "Revizija **")

        let letterThenStar = parser.parse("Revizija ~l **", projects: [], today: today)
        #expect(letterThenStar.effort == KEffort.m)
        #expect(letterThenStar.title == "Revizija ~l")
    }
}
