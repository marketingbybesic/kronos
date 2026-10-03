import Testing
@testable import KronosCore

/// The deterministic breakdown a Large task gets when it has no steps: 3 to 7 verb-first steps, the
/// first one equal to the first move, and nothing that only repeats "finish the task".
struct DeterministicBreakdownTests {

    /// Phrases that are filler, written out by hand (English and Croatian). A step containing one of
    /// them restates completion instead of moving the work forward.
    static let filler: [String] = [
        "mark the task finished", "mark the task as done", "check the result against",
        "označi zadatak završenim", "provjeri rezultat protiv",
    ]

    static func isFiller(_ step: String) -> Bool {
        let lower = step.lowercased()
        return filler.contains { lower.contains($0) }
    }

    /// (title, notes, language) rows: a verb-led title, a noun-phrase title, a Croatian title, with
    /// and without notes.
    static let rows: [(title: String, notes: String, language: Lang)] = [
        ("Prepare the quarterly report for the board", "", .en),
        ("Prepare the quarterly report for the board", "Numbers are in the sheet", .en),
        ("Quarterly report", "", .en),
        ("Napiši izvještaj za treće tromjesečje", "", .hr),
        ("Napiši izvještaj za treće tromjesečje", "Brojke su u tablici", .hr),
        ("Izvještaj", "", .hr),
    ]

    @Test func everyRowYieldsThreeToSevenVerbFirstSteps() {
        for row in Self.rows {
            let result = DeterministicBreakdown.steps(title: row.title, notes: row.notes, language: row.language)
            let count = result.subtasks.count
            #expect((3...7).contains(count), "\(row.title) [\(row.language)] gave \(count) steps: \(result.subtasks)")
            for step in result.subtasks {
                let verdict = FirstMoveLint.lint(step, language: row.language, dreadMode: false)
                #expect(verdict.isPass, "\"\(step)\" is not verb-first: \(verdict)")
            }
            #expect(result.isDeterministic)
        }
    }

    @Test func noFillerStepAnywhere() {
        for row in Self.rows {
            let result = DeterministicBreakdown.steps(title: row.title, notes: row.notes, language: row.language)
            for step in result.subtasks {
                #expect(!Self.isFiller(step), "filler step: \"\(step)\"")
            }
        }
    }

    @Test func stepOneIsTheFirstMove() {
        for row in Self.rows {
            let result = DeterministicBreakdown.steps(title: row.title, notes: row.notes, language: row.language)
            #expect(result.subtasks.first == result.firstMove)
            let move = DeterministicFirstMove.generate(title: row.title, firstMoveURL: nil, hasOpenSubtask: false,
                                                       notesNonEmpty: !row.notes.isEmpty, dread: false, language: row.language)
            #expect(result.firstMove == move)
        }
    }

    /// Hand-written expectation for one row, so the shape of the list is pinned, not only its bounds.
    @Test func plainEnglishRowIsExactlyThisList() {
        let result = DeterministicBreakdown.steps(title: "Prepare the quarterly report for the board", notes: "", language: .en)
        #expect(result.subtasks == [
            "Open a blank note and list what is needed.",
            "Write one sentence about what done looks like.",
            "Write a list of what is still needed.",
            "Open the first item on the list and write its first line.",
        ])
    }

    /// Positive control: the detector must flag the lines the previous version produced, otherwise
    /// "no filler" above proves nothing.
    @Test func detectorFlagsTheOldFillerLines() {
        #expect(Self.isFiller("Mark the task finished."))
        #expect(Self.isFiller("Check the result against the original request."))
        #expect(Self.isFiller("Označi zadatak završenim."))
        #expect(Self.isFiller("Provjeri rezultat protiv izvornog zahtjeva."))
        #expect(!Self.isFiller("Write a list of what is still needed."))
    }
}
