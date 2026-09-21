import Testing
@testable import KronosCore

/// The 20-case first-move rule table, verbatim.
struct FirstMoveLintTests {

    // MARK: PASS (10)

    @Test func p1OpenAcmeFolder() {
        #expect(FirstMoveLint.lint("Open the Acme September folder in Drive", language: .en, dreadMode: false).isPass)
    }
    @Test func p2WriteUmbrellaCaption() {
        #expect(FirstMoveLint.lint("Write the first sentence of the Umbrella caption", language: .en, dreadMode: false).isPass)
    }
    @Test func p3DialNumber() {
        #expect(FirstMoveLint.lint("Dial +385 91 608 9242", language: .en, dreadMode: false).isPass)
    }
    @Test func p4OpenTerminalAndRun() {
        #expect(FirstMoveLint.lint("Open Terminal and run dig +short behafni.com", language: .en, dreadMode: false).isPass)
    }
    @Test func p5CopyStripeID() {
        #expect(FirstMoveLint.lint("Copy the Stripe payment ID from invoice #194", language: .en, dreadMode: false).isPass)
    }
    @Test func p6OtvoriAlexovMail() {
        #expect(FirstMoveLint.lint("Otvori Alexov mail od 14.09. i pročitaj prvi odlomak", language: .hr, dreadMode: false).isPass)
    }
    @Test func p7PrintDostavaPDF() {
        #expect(FirstMoveLint.lint("Print the Dostava u plusu PDF, pages 1-3", language: .en, dreadMode: false).isPass)
    }
    @Test func p8OpenDraftReplyDreadSafe() {
        #expect(FirstMoveLint.lint("Open the draft reply to Alex", language: .en, dreadMode: true).isPass)
    }
    @Test func p9CreateFileNamedPath() {
        #expect(FirstMoveLint.lint("Create a file named acm-audit.md in ~/Downloads", language: .en, dreadMode: false).isPass)
    }
    @Test func p10NapisiJednuRecenicu() {
        #expect(FirstMoveLint.lint("Napiši jednu rečenicu o cijeni u bilješke", language: .hr, dreadMode: false).isPass)
    }

    // MARK: FAIL (10)

    @Test func f1DecideWhichClient() {
        let v = FirstMoveLint.lint("Decide which client to call first", language: .en, dreadMode: false)
        #expect(reasonContains(v, "decision verb"))
    }
    @Test func f2PlanTheOutline() {
        let v = FirstMoveLint.lint("Plan the outline", language: .en, dreadMode: false)
        #expect(reasonContains(v, "decision verb"))
    }
    @Test func f3StartWorkingOnReport() {
        let v = FirstMoveLint.lint("Start working on the Globex report", language: .en, dreadMode: false)
        #expect(reasonContains(v, "decision verb"))
    }
    /// Required gate test: `firstMoveLintRejectsVagueVerb`.
    @Test func firstMoveLintRejectsVagueVerb() {
        let v = FirstMoveLint.lint("Open the document", language: .en, dreadMode: false)
        #expect(reasonContains(v, "no specific object"))
    }
    @Test func f5ReviewOptionsChain() {
        let v = FirstMoveLint.lint("Review the options and then pick one and send it", language: .en, dreadMode: false)
        #expect(reasonContains(v, "decision verb"))
    }
    @Test func f6FigureOutWhatAlexNeeds() {
        let v = FirstMoveLint.lint("Figure out what Alex needs", language: .en, dreadMode: false)
        #expect(reasonContains(v, "decision verb"))
    }
    @Test func f7TooLongChain() {
        let v = FirstMoveLint.lint(
            "Open the Acme folder, check the photos, pick three, export them and upload to Drive",
            language: .en, dreadMode: false)
        #expect(reasonContains(v, "too long"))
    }
    @Test func f8TryToReplyHedging() {
        let v = FirstMoveLint.lint("Try to reply to Alex if you have time", language: .en, dreadMode: false)
        #expect(reasonContains(v, "hedging"))
    }
    @Test func f9BreakThisTaskDownMeta() {
        let v = FirstMoveLint.lint("Break this task down into subtasks", language: .en, dreadMode: false)
        #expect(reasonContains(v, "meta-task"))
    }
    @Test func f10ReplyToAlexDreadOnlyFailsInDreadMode() {
        let notDread = FirstMoveLint.lint("Reply to Alex", language: .en, dreadMode: false)
        #expect(notDread.isPass)
        let dread = FirstMoveLint.lint("Reply to Alex", language: .en, dreadMode: true)
        #expect(reasonContains(dread, "bounded opener"))
    }

    // MARK: Deterministic templates pass their own lint (spec §2.3)

    @Test func deterministicTemplatesAllPassLintEN() {
        let cases: [(hasSubtask: Bool, notes: Bool, dread: Bool)] = [
            (true, false, false), (false, true, false), (false, false, true), (false, false, false)
        ]
        for c in cases {
            let move = DeterministicFirstMove.generate(
                title: "Nazvati Karla oko rujanske fakture sutra i jos nesto",
                firstMoveURL: nil, hasOpenSubtask: c.hasSubtask, notesNonEmpty: c.notes,
                dread: c.dread, language: .en)
            // A Croatian title gets a Croatian move even in an English app.
            #expect(FirstMoveLint.lint(move, language: .hr, dreadMode: c.dread).isPass, "failed for \(move)")
        }
    }

    @Test func deterministicTemplatesAllPassLintHR() {
        let cases: [(hasSubtask: Bool, notes: Bool, dread: Bool)] = [
            (true, false, false), (false, true, false), (false, false, true), (false, false, false)
        ]
        for c in cases {
            let move = DeterministicFirstMove.generate(
                title: "Nazvati Karla oko rujanske fakture sutra i jos nesto",
                firstMoveURL: nil, hasOpenSubtask: c.hasSubtask, notesNonEmpty: c.notes,
                dread: c.dread, language: .hr)
            #expect(FirstMoveLint.lint(move, language: .hr, dreadMode: c.dread).isPass, "failed for \(move)")
        }
    }

    @Test func deterministicTemplateURLPassesLint() {
        let move = DeterministicFirstMove.generate(title: "Anything", firstMoveURL: "https://drive.google.com/x",
                                                    hasOpenSubtask: false, notesNonEmpty: false,
                                                    dread: false, language: .en)
        #expect(FirstMoveLint.lint(move, language: .en, dreadMode: false).isPass)
    }

    @Test func moveFollowsTitleLanguageNotAppLanguage() {
        let hr = DeterministicFirstMove.generate(title: "Nazovi Alexa oko termina", firstMoveURL: nil,
                                                  hasOpenSubtask: false, notesNonEmpty: false, dread: false, language: .en)
        #expect(!hr.hasPrefix("Open "), "English template around a Croatian title: \(hr)")
        let noun = DeterministicFirstMove.generate(title: "Račun za struju", firstMoveURL: nil,
                                                    hasOpenSubtask: false, notesNonEmpty: false, dread: false, language: .en)
        #expect(noun.hasPrefix("Otvori "), "\(noun)")
        let en = DeterministicFirstMove.generate(title: "Call Alex about the invoice", firstMoveURL: nil,
                                                  hasOpenSubtask: false, notesNonEmpty: false, dread: false, language: .hr)
        #expect(!en.hasPrefix("Otvori "), "\(en)")
    }

    @Test func fallbackNeverEmbedsACutOffTitle() {
        for dread in [true, false] {
            let move = DeterministicFirstMove.generate(title: "Reply to Alex about the unpaid invoice from August",
                                                        firstMoveURL: nil, hasOpenSubtask: false,
                                                        notesNonEmpty: false, dread: dread, language: .en)
            #expect(!move.contains("Reply"), "title fragment embedded: \(move)")
            #expect(FirstMoveLint.lint(move, language: .en, dreadMode: dread).isPass, "\(move)")
        }
    }

    // MARK: Verb-led title grammar (2026-09-19 fix — was "Open Send the
    // September invoice to Alex and write the first line")

    /// Table of verb-led titles -> the specific, natural opener each verb
    /// family must produce. Asserts the exact grammatical fix, not just
    /// "passes lint" — a generator could pass lint while still reading oddly.
    @Test func deterministicFirstMoveIsGrammaticalForVerbLedTitles() {
        let cases: [(title: String, language: Lang, expected: String)] = [
            ("Send the September invoice to Alex", .en, "Open Mail and start a new message to Alex."),
            ("Call Alex about the delivery", .en, "Open Contacts and find Alex's number."),
            ("Write the September report", .en, "Open a blank document and type the title."),
            ("Pay the September invoice", .en, "Open your banking app and log in."),
            ("Pošalji Alexu račun za rujan", .hr, "Otvori Mail i započni novu poruku za Alexu."),
            ("Nazovi Alexa oko isporuke", .hr, "Otvori Kontakte i pronađi broj za Alexa."),
            ("Napiši rujanski izvještaj", .hr, "Otvori prazan dokument i upiši naslov."),
            ("Plati rujanski račun", .hr, "Otvori bankovnu aplikaciju i prijavi se.")
        ]
        for c in cases {
            let move = DeterministicFirstMove.generate(title: c.title, firstMoveURL: nil,
                                                        hasOpenSubtask: false, notesNonEmpty: false,
                                                        dread: false, language: c.language)
            #expect(move == c.expected, "title '\(c.title)' -> '\(move)', expected '\(c.expected)'")
        }
    }

    /// A title with NO recognised leading verb still gets the original
    /// grammatical noun-phrase template — the fix must not regress this case.
    @Test func deterministicFirstMoveKeepsNounPhraseTemplateWhenNoVerbLeads() {
        let move = DeterministicFirstMove.generate(title: "Acme September folder cleanup", firstMoveURL: nil,
                                                    hasOpenSubtask: false, notesNonEmpty: false,
                                                    dread: false, language: .en)
        #expect(move == "Open the notes for this task and write the first line")
    }

    /// Every string this generator can produce must pass its own lint — a
    /// generator the linter rejects is a bug.
    /// Exercises the full cross product of verb family x condition x
    /// language x dread, including titles with no recognised verb and an
    /// empty object after the verb.
    @Test func deterministicFirstMoveAlwaysPassesTheLint() {
        let titles: [Lang: [String]] = [
            .en: ["Send the September invoice to Alex", "Call Alex", "Write the report",
                  "Pay the invoice", "Book the flight to Zagreb", "Buy a new charger",
                  "Fix the printer", "Review the September contract", "Prepare the meeting notes",
                  "Acme September folder cleanup", "Send"],
            .hr: ["Pošalji Alexu račun za rujan", "Nazovi Alexa", "Napiši izvještaj",
                  "Plati račun", "Rezerviraj let za Zagreb", "Kupi novi punjač",
                  "Popravi printer", "Pregledaj rujanski ugovor", "Pripremi bilješke za sastanak",
                  "Rujanska mapa Acme", "Pošalji"]
        ]
        for (lang, titleList) in titles {
            for title in titleList {
                for (hasSubtask, notes, dread) in [(false, false, false), (true, false, false),
                                                    (false, true, false), (false, false, true)] {
                    let move = DeterministicFirstMove.generate(title: title, firstMoveURL: nil,
                                                                hasOpenSubtask: hasSubtask, notesNonEmpty: notes,
                                                                dread: dread, language: lang)
                    let verdict = FirstMoveLint.lint(move, language: lang, dreadMode: dread)
                    #expect(verdict.isPass, "title '\(title)' [\(lang), subtask=\(hasSubtask) notes=\(notes) dread=\(dread)] -> '\(move)' failed: \(verdict)")
                    #expect(!move.contains("!"))
                }
            }
        }
    }

    private func reasonContains(_ v: LintVerdict, _ needle: String) -> Bool {
        if case .fail(let reason) = v { return reason.contains(needle) }
        return false
    }
}
