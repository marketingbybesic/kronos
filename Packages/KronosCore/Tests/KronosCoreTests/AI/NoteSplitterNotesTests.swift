// `NoteSplitter.notes(in:)`: a plain (unmarked) line at the task's own level, right after the
// task line, becomes that task's notes instead of falling through into a bogus task of its own
// — a paste of loose notes should turn into tasks, subtasks and descriptions in one pass, not
// scatter plain sentences as extra tasks. Ends at the next task line, a subtask, or a blank line
// — hand-tabled from `groupLines`'s documented rule, not derived from the code under test.
import Testing
import Foundation
@testable import KronosCore

struct NoteSplitterNotesTests {
    private let today = Day.today()

    @Test func plainLineAfterATaskLineBecomesItsNotes() {
        let text = "Onboard Globex\nThe contact is Alex, contract signed last week."
        let proposals = NoteSplitter.split(text, today: today)
        #expect(proposals.count == 1)
        #expect(proposals.first?.title == "Onboard Globex")
        let notes = NoteSplitter.notes(in: text)
        #expect(notes[proposals[0].sourceLine] == "The contact is Alex, contract signed last week.")
    }

    @Test func multiplePlainLinesJoinIntoOneNotesBlockWithNewlines() {
        let text = "Prepare the deck\nCover the Q3 numbers.\nKeep it under ten slides."
        let proposals = NoteSplitter.split(text, today: today)
        #expect(proposals.count == 1)
        let notes = NoteSplitter.notes(in: text)
        #expect(notes[proposals[0].sourceLine] == "Cover the Q3 numbers.\nKeep it under ten slides.")
    }

    @Test func aBlankLineEndsTheNotesRun() {
        let text = "Prepare the deck\nCover the Q3 numbers.\n\nBook the venue"
        let proposals = NoteSplitter.split(text, today: today)
        #expect(proposals.count == 2)
        #expect(proposals[1].title == "Book the venue")
        let notes = NoteSplitter.notes(in: text)
        #expect(notes[proposals[0].sourceLine] == "Cover the Q3 numbers.")
        #expect(notes[proposals[1].sourceLine] == nil)
    }

    // Without a blank line, a flat unmarked run of "task / notes / task" text has no marker
    // that tells a plain notes sentence apart from the next plain task line — the deterministic
    // pass cannot resolve that ambiguity (only a model reading meaning can, which is the AI
    // path's job — see PromptTemplates.extractSystem's own `notes` field). So a second
    // unmarked line right after the first also reads as more of the SAME task's notes here;
    // a blank line (the realistic shape for "one paragraph per task", matching how sample notes
    // in CaptureFixtures are bullet-separated) is what actually closes a run.
    @Test func consecutivePlainLinesWithNoBlankLineAllJoinTheSameTasksNotes() {
        let text = "Call Alex about the invoice\nHe asked for the PDF version\nBook flight to Zagreb"
        let proposals = NoteSplitter.split(text, today: today)
        #expect(proposals.count == 1)
        #expect(proposals[0].title == "Call Alex about the invoice")
        let notes = NoteSplitter.notes(in: text)
        #expect(notes[proposals[0].sourceLine] == "He asked for the PDF version\nBook flight to Zagreb")
    }

    @Test func aBulletedLineAfterATaskStaysASubtaskNeverNotes() {
        let text = "Onboard Globex\n- send the contract\n- schedule the kickoff"
        let notes = NoteSplitter.notes(in: text)
        #expect(notes.isEmpty)
    }

    @Test func aDeeperIndentedPlainLineStaysAWrappedTitleOrSubtaskNeverNotes() {
        // A deeper, unmarked, lowercase-starting line after a bulleted, non-stopper-ending
        // parent is the existing wrapped-title-continuation case (NoteSplitterWrappedContinuationTests)
        // — it must stay merged into the title, never become notes.
        let text = "- Write the proposal\n  for the September delivery"
        let proposals = NoteSplitter.split(text, today: today)
        #expect(proposals.first?.title == "Write the proposal for the September delivery")
        #expect(NoteSplitter.notes(in: text).isEmpty)
    }

    @Test func taskWithNoFollowingPlainLineHasNoNotes() {
        let text = "- Pay the invoice\n- Renew the domain"
        #expect(NoteSplitter.notes(in: text).isEmpty)
    }

    @Test func croatianPlainNotesLineIsRecognisedTheSameWay() {
        let text = "Nazvati dobavljača za Globex\nTreba potvrditi cijenu do petka."
        let proposals = NoteSplitter.split(text, today: today)
        #expect(proposals.count == 1)
        let notes = NoteSplitter.notes(in: text)
        #expect(notes[proposals[0].sourceLine] == "Treba potvrditi cijenu do petka.")
    }

    @Test func aHeadingLineEndsTheNotesRunEvenWithoutABlankLine() {
        let text = "Onboard Globex\nThe contact is Alex.\nBiz:\nBook flight"
        let proposals = NoteSplitter.split(text, today: today, projectNames: ["Biz"])
        #expect(proposals.count == 2)
        let notes = NoteSplitter.notes(in: text, projectNames: ["Biz"])
        #expect(notes[proposals[0].sourceLine] == "The contact is Alex.")
        #expect(notes[proposals[1].sourceLine] == nil)
    }
}
