// `CaptureModel.upgrade(with:)` — the merge seam AFTER `ExtractOutlineValidator`, deciding what
// the user SEES in Review — had no unit tests because it lived entirely in the app target.
// `CaptureMerge.merge` (AI/CaptureMerge.swift) is the pure extraction; these tests prove two
// suspected defects were REAL (a hand-mirrored copy of the OLD buggy algorithm, `oldBuggyUpgrade`
// below, reproduces each one failing), then prove the new `CaptureMerge.merge` fixes both.
//
// Every test here can fail: each is paired with an assertion that breaks under the bug it
// guards against, not a tautology.

import Testing
import Foundation
@testable import KronosCore

@MainActor
struct CaptureMergeTests {

    private let today = Day.today()

    // MARK: - Old buggy algorithm, hand-mirrored from CaptureModel.upgrade(with:) as it stood
    // BEFORE this round (Kronos/Capture/CaptureModel.swift, git history) — reproduces defects A
    // and B failing, proving they were real before CaptureMerge existed. Never used by the app;
    // exists ONLY so this test file can show "failing on old code, passing on new code" without
    // requiring two live copies of the real merge logic in the app target.
    private static func oldBuggyUpgrade(rows: [CaptureMergeRow], aiTasks: [ProposedTask]) -> [CaptureMergeRow] {
        var rows = rows
        var remaining = aiTasks
        var seenLines: Set<String> = []
        for i in rows.indices {
            let key = KTextFold.fold(rows[i].proposal.sourceLine)
            seenLines.insert(key)
            guard !rows[i].isEdited,
                  let matchIndex = remaining.firstIndex(where: { KTextFold.fold($0.sourceLine).contains(key) })
            else { continue }
            let wasTicked = rows[i].isTicked
            let upgraded = remaining.remove(at: matchIndex)
            rows[i].proposal = upgraded
            rows[i].isTicked = wasTicked
        }
        let newOnes = remaining.filter { candidate in
            !seenLines.contains { KTextFold.fold(candidate.sourceLine).contains($0) }
        }
        rows.append(contentsOf: newOnes.map {
            CaptureMergeRow(id: UUID(), proposal: $0, isTicked: !$0.isDuplicateOfOpenTask, isEdited: false, subtasks: $0.subtasks)
        })
        return rows
    }

    private func row(_ title: String, sourceLine: String, notes: String? = nil,
                     isEdited: Bool = false, isTicked: Bool = true) -> CaptureMergeRow {
        CaptureMergeRow(id: UUID(),
                        proposal: ProposedTask(title: title, priority: .none, effort: .none,
                                               notes: notes, sourceLine: sourceLine),
                        isTicked: isTicked, isEdited: isEdited, subtasks: [])
    }

    private func aiTask(_ title: String, notes: String? = nil, sourceLine: String,
                        subtasks: [String] = []) -> ProposedTask {
        ProposedTask(title: title, priority: .medium, effort: .s, notes: notes,
                    subtasks: subtasks, sourceLine: sourceLine, isFromAI: true)
    }

    // MARK: - A. Second (and third) task of a paragraph is silently lost

    @Test func defectA_confirmedOnOldCode_secondAndThirdTaskVanish() {
        let paragraph = "Call Alex about the invoice and send Maria the contract by Friday. Also book the meeting room for Tuesday."
        let rows = [row("Call Alex about the invoice and send Maria the contract by Friday. Also book the meeting room for Tuesday.",
                        sourceLine: paragraph)]
        // All three AI tasks are grounded in the SAME single source line (the whole paragraph) —
        // exactly what `ExtractOutlineValidator`'s re-pointing does for a one-line source, per
        // its own `sourceLines.count == 1` fallback.
        let ai = [
            aiTask("Call Alex about the invoice", sourceLine: paragraph),
            aiTask("Send Maria the contract by Friday", sourceLine: paragraph),
            aiTask("Book the meeting room for Tuesday", sourceLine: paragraph),
        ]
        let result = Self.oldBuggyUpgrade(rows: rows, aiTasks: ai)
        #expect(result.count == 1, "confirms the bug: old code kept only 1 row, dropping 2 of the 3 AI tasks silently")
    }

    @Test func defectA_fixed_allThreeTasksBecomeSeparateRows() {
        let paragraph = "Call Alex about the invoice and send Maria the contract by Friday. Also book the meeting room for Tuesday."
        let rows = [row("Call Alex about the invoice and send Maria the contract by Friday. Also book the meeting room for Tuesday.",
                        sourceLine: paragraph)]
        let ai = [
            aiTask("Call Alex about the invoice", sourceLine: paragraph),
            aiTask("Send Maria the contract by Friday", sourceLine: paragraph),
            aiTask("Book the meeting room for Tuesday", sourceLine: paragraph),
        ]
        let result = CaptureMerge.merge(rows: rows, aiTasks: ai)
        #expect(result.count == 3)
        #expect(result.map(\.proposal.title) == [
            "Call Alex about the invoice", "Send Maria the contract by Friday", "Book the meeting room for Tuesday"
        ])
        // The first AI task replaces the original row IN PLACE (same id), the rest are NEW rows
        // inserted right after it — never appended at the very end, keeping paragraph order.
        #expect(result[0].id == rows[0].id)
        #expect(result[1].id != rows[0].id)
        #expect(result[2].id != rows[0].id)
    }

    // MARK: - B. Duplicate row when sourceLine is re-pointed to a notes line

    @Test func defectB_confirmedOnOldCode_taskAppearsTwice() {
        let bulletLine = "Book flight to the offsite !!! ***"
        let notesLine = "Budget approved, do not exceed 3000."
        // The deterministic row's own sourceLine is the bullet-stripped line; its `notes` field
        // already holds the plain follow-up line, exactly as `CaptureModel.findTasks()` sets it
        // from `NoteSplitter.notes(in:)`.
        let rows = [row("Book flight to the offsite", sourceLine: bulletLine, notes: notesLine)]
        // The AI task is grounded and re-pointed to the NOTES line, not the bullet line — this is
        // real, measured behaviour from `ExtractOutlineValidator.validateExtractOutline`'s own
        // re-pointing (notes-verbatim-match wins over title-overlap when both are available).
        let ai = [aiTask("Book flight to the offsite", notes: notesLine, sourceLine: notesLine)]
        let result = Self.oldBuggyUpgrade(rows: rows, aiTasks: ai)
        #expect(result.count == 2, "confirms the bug: old code appended a duplicate row instead of upgrading the existing one")
        #expect(result.filter { KTextFold.fold($0.proposal.title) == KTextFold.fold("Book flight to the offsite") }.count == 2)
    }

    @Test func defectB_fixed_notesLineStillMatchesItsOwnRow() {
        let bulletLine = "Book flight to the offsite !!! ***"
        let notesLine = "Budget approved, do not exceed 3000."
        let rows = [row("Book flight to the offsite", sourceLine: bulletLine, notes: notesLine)]
        let ai = [aiTask("Book flight to the offsite", notes: notesLine, sourceLine: notesLine)]
        let result = CaptureMerge.merge(rows: rows, aiTasks: ai)
        #expect(result.count == 1)
        #expect(result[0].id == rows[0].id)
        #expect(result[0].proposal.notes == notesLine)
    }

    // MARK: - A single-task paragraph end to end (1 row in, 1 upgraded row out, notes filled)

    @Test func ownersParagraph_oneRowInOneUpgradedRowOutNotesFilled() {
        let source = "Call Alex about the invoice. He asked for the PDF version, not the scan."
        let rows = [row("Call Alex about the invoice. He asked for the PDF version, not the scan.", sourceLine: source)]
        let ai = [aiTask("Call Alex about the invoice", notes: "He asked for the PDF version, not the scan.", sourceLine: source)]
        let result = CaptureMerge.merge(rows: rows, aiTasks: ai)
        #expect(result.count == 1)
        #expect(result[0].proposal.title == "Call Alex about the invoice")
        #expect(result[0].proposal.notes == "He asked for the PDF version, not the scan.")
        #expect(result[0].id == rows[0].id)
    }

    // MARK: - An edited row survives untouched, an AI task for it is dropped

    @Test func editedRowSurvivesUntouchedAiTaskForItIsDropped() {
        let source = "Call the bank about the loan"
        var edited = row("My own better title", sourceLine: source, isEdited: true)
        edited.proposal.notes = "hand-typed note"
        let ai = [aiTask("Call the bank", notes: "AI notes", sourceLine: source)]
        let result = CaptureMerge.merge(rows: [edited], aiTasks: ai)
        #expect(result.count == 1)
        #expect(result[0].proposal.title == "My own better title")
        #expect(result[0].proposal.notes == "hand-typed note")
        #expect(result[0].isEdited == true)
    }

    // MARK: - A ticked-off row's tick survives replacement

    @Test func tickedOffRowStaysTickedOffAfterReplacement() {
        let source = "Call the bank about the loan"
        let untickedRow = row("Call the bank about the loan", sourceLine: source, isTicked: false)
        let ai = [aiTask("Call the bank about the loan", sourceLine: source)]
        let result = CaptureMerge.merge(rows: [untickedRow], aiTasks: ai)
        #expect(result.count == 1)
        #expect(result[0].isTicked == false)
    }

    // MARK: - A bullet list of 5 where the AI returns only 3: 5 rows out, 3 upgraded, 2 plain

    @Test func bulletListOfFiveAiReturnsOnlyThree_fiveRowsOutThreeUpgradedTwoPlain() {
        let lines = (1...5).map { "Task \($0) with enough letters" }
        let rows = lines.map { row($0, sourceLine: $0) }
        // AI answers for tasks 1, 3, 5 only (2 and 4 dropped by the validator, e.g. a missing marker).
        let ai = [
            aiTask("Task 1 with enough letters, improved", sourceLine: lines[0]),
            aiTask("Task 3 with enough letters, improved", sourceLine: lines[2]),
            aiTask("Task 5 with enough letters, improved", sourceLine: lines[4]),
        ]
        let result = CaptureMerge.merge(rows: rows, aiTasks: ai)
        #expect(result.count == 5)
        #expect(result[0].proposal.title == "Task 1 with enough letters, improved")
        #expect(result[1].proposal.title == "Task 2 with enough letters")   // untouched: no AI task for it.
        #expect(result[2].proposal.title == "Task 3 with enough letters, improved")
        #expect(result[3].proposal.title == "Task 4 with enough letters")   // untouched.
        #expect(result[4].proposal.title == "Task 5 with enough letters, improved")
    }

    // MARK: - The no-task paragraph where the AI is rejected: row unchanged (real property to keep)

    @Test func noTaskParagraphAiRejected_rowStaysExactlyAsDeterministicLeftIt() {
        // Mirrors `CaptureModel.upgrade`'s own `guard !result.isDeterministic else { return }` —
        // when the AI candidate is rejected entirely, `extractTasks` returns the deterministic
        // result and `CaptureModel` never calls `CaptureMerge.merge` at all. This test instead
        // proves the underlying property directly: an EMPTY `aiTasks` array (the shape `merge`
        // would see if it were ever called with nothing to apply) changes no row.
        let source = "nothing cut, buttons wrap to two rows on narrow width"
        let untouched = row("nothing cut, buttons wrap to two rows on narrow width", sourceLine: source)
        let result = CaptureMerge.merge(rows: [untouched], aiTasks: [])
        #expect(result.count == 1)
        #expect(result[0].proposal.title == untouched.proposal.title)
        #expect(result[0].id == untouched.id)
    }

    // MARK: - Never two rows with the same folded title from the same block

    @Test func neverTwoRowsWithTheSameFoldedTitleFromTheSameBlock() {
        let source = "Call Alex about the invoice."
        let rows = [row("Call Alex about the invoice.", sourceLine: source)]
        // Two AI tasks grounded in the same row with the SAME folded title (a model repeating
        // itself) must not produce two identical rows.
        let ai = [
            aiTask("Call Alex about the invoice", sourceLine: source),
            aiTask("call alex about the invoice", sourceLine: source),   // same title, different case.
        ]
        let result = CaptureMerge.merge(rows: rows, aiTasks: ai)
        #expect(result.count == 1)
    }

    // MARK: - Outline-derived subtasks merge in without folded duplicates

    @Test func outlineSubtasksMergeWithoutFoldedDuplicates() {
        let source = "Ship the release"
        var existing = row("Ship the release", sourceLine: source)
        existing.subtasks = ["write changelog"]
        let ai = [aiTask("Ship the release", sourceLine: source, subtasks: ["Write changelog", "tag the build"])]
        let result = CaptureMerge.merge(rows: [existing], aiTasks: ai)
        #expect(result.count == 1)
        #expect(result[0].subtasks == ["write changelog", "tag the build"])
    }
}
