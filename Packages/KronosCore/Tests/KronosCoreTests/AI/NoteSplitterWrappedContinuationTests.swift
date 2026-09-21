// Hand-tabled: NoteSplitter.joinWrappedContinuations / isWrappedContinuation, the narrow
// Capture-only pre-pass that keeps a hard-wrapped pasted title merged while leaving every
// other indented shape to TaskOutline's own subtask rule. Each expectation below is worked
// out BY HAND from the four conditions in NoteSplitter.swift's doc comment before running —
// not derived from the code under test.
import Testing
import Foundation
@testable import KronosCore

struct NoteSplitterWrappedContinuationTests {
    private let today = Day.today()

    /// (1) The old wrapped case: bulleted parent, deeper unmarked lowercase child, parent
    /// does not end in a stopper -> still ONE task, title merged, exactly as before.
    @Test func oldWrappedCaseStillMergesIntoOneTask() {
        let text = "- Write the proposal\n  for the September delivery\n- Second task"
        let proposals = NoteSplitter.split(text, today: today)
        #expect(proposals.count == 2)
        #expect(proposals[0].title.contains("for the September delivery"))
    }

    /// (2) A bulleted indented child is a subtask, never a continuation (condition 2: child
    /// must have NO marker of its own).
    @Test func bulletedIndentedChildIsASubtaskNotAContinuation() {
        let text = "- Launch page\n  - write copy\n- Send recap"
        let proposals = NoteSplitter.split(text, today: today)
        #expect(proposals.count == 2)
        #expect(proposals[0].title == "Launch page")
        let subtasks = NoteSplitter.subtasks(in: text)
        #expect(subtasks[proposals[0].sourceLine] == ["write copy"])
    }

    /// (3) A plain (non-bulleted) parent never triggers the pre-pass (condition 1) — an
    /// indented child under it is a subtask, exactly like TaskOutline on its own.
    @Test func tabIndentedChildUnderAPlainParentIsASubtask() {
        let text = "Ship newsletter\n\twrite the intro\nBook the dentist"
        let proposals = NoteSplitter.split(text, today: today)
        #expect(proposals.count == 2)
        #expect(proposals[0].title == "Ship newsletter")
        let subtasks = NoteSplitter.subtasks(in: text)
        #expect(subtasks[proposals[0].sourceLine] == ["write the intro"])
    }

    /// (4) A parent ending in ':' never continues (condition 4) even though every other
    /// condition would otherwise hold — reads as "a subtask because of the colon".
    @Test func parentEndingInColonForcesASubtaskNotAContinuation() {
        let text = "- Call Alex:\n  ask about the invoice"
        let proposals = NoteSplitter.split(text, today: today)
        #expect(proposals.count == 1)
        #expect(proposals[0].title == "Call Alex:")
        let subtasks = NoteSplitter.subtasks(in: text)
        #expect(subtasks[proposals[0].sourceLine] == ["ask about the invoice"])
    }

    /// (5) A capitalised child is a subtask, not a continuation (condition 3) — a wrapped
    /// title continuation reads as one broken sentence, which never starts a new capital.
    @Test func capitalisedChildForcesASubtaskNotAContinuation() {
        let text = "- Plan\n  Book the flight"
        let proposals = NoteSplitter.split(text, today: today)
        #expect(proposals.count == 1)
        #expect(proposals[0].title == "Plan")
        let subtasks = NoteSplitter.subtasks(in: text)
        #expect(subtasks[proposals[0].sourceLine] == ["Book the flight"])
    }

    // MARK: Extra edge cases beyond the five named ones

    /// Other stoppers besides ':' also block the merge (condition 4's full set).
    @Test func otherSentenceStoppersAlsoForceASubtask() {
        for stopper in [".", ";", "!", "?"] {
            let text = "- Call Alex\(stopper)\n  ask about the invoice"
            let proposals = NoteSplitter.split(text, today: today)
            #expect(proposals.count == 1, "stopper \(stopper)")
            let subtasks = NoteSplitter.subtasks(in: text)
            #expect(subtasks[proposals[0].sourceLine] == ["ask about the invoice"], "stopper \(stopper)")
        }
    }

    /// Croatian diacritics count as letters for the lowercase check (condition 3):
    /// `Character.isLowercase` is true for Croatian diacritics too.
    @Test func croatianDiacriticLowercaseStartStillMerges() {
        let text = "- Napisati mail\n  čim prije stigne odgovor"
        let proposals = NoteSplitter.split(text, today: today)
        #expect(proposals.count == 1)
        #expect(proposals[0].title.contains("čim prije stigne odgovor"))
    }

    /// Same diacritic, but capitalised (Č), must still block the merge like any other
    /// capital letter.
    @Test func capitalisedCroatianDiacriticForcesASubtask() {
        let text = "- Napisati mail\n  Čim prije stigni na sastanak"
        let proposals = NoteSplitter.split(text, today: today)
        #expect(proposals.count == 1)
        #expect(proposals[0].title == "Napisati mail")
        let subtasks = NoteSplitter.subtasks(in: text)
        #expect(subtasks[proposals[0].sourceLine] == ["Čim prije stigni na sastanak"])
    }

    /// A checked checkbox line is never a continuation source or target — it is skipped
    /// entirely upstream of this pre-pass reading it as a parent or a child.
    @Test func checkedBoxNeverParticipatesInAContinuation() {
        let text = "- [x] Done already\n  lowercase trailing text\n- Real task"
        let proposals = NoteSplitter.split(text, today: today)
        #expect(proposals.map(\.title) == ["lowercase trailing text", "Real task"])
    }

    // MARK: Pure function directly (isWrappedContinuation), one row per condition

    @Test func isWrappedContinuationHandTable() {
        let cases: [(previous: String, next: String, expected: Bool)] = [
            ("- Write the proposal", "  for the September delivery", true),
            ("- Launch page", "  - write copy", false),
            ("Ship newsletter", "\twrite the intro", false),
            ("- Call Alex:", "  ask about the invoice", false),
            ("- Plan", "  Book the flight", false),
            ("- Plan", "  book the flight", true),     // same as above but lowercase -> merges
            ("- Task", "not indented at all", false),   // condition 2: same level, no deeper indent
        ]
        for c in cases {
            let result = NoteSplitter.isWrappedContinuation(of: c.previous, next: c.next)
            #expect(result == c.expected, "previous=\(c.previous) next=\(c.next)")
        }
    }
}
