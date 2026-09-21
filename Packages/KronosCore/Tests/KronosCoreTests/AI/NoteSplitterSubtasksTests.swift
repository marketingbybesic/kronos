// `NoteSplitter.subtasks(in:)` — the outline-driven subtasks a "generate tasks" pass produces,
// keyed by each proposal's own `sourceLine`. Hand-tabled: each expectation is worked out by
// hand from TaskOutline's own documented rule, not derived from the code under test. See
// NoteSplitterWrappedContinuationTests.swift for the narrow Capture-only pre-pass that keeps a
// genuinely wrapped title merged while every OTHER indented shape — including a plain line
// under a bulleted parent that does NOT look like a wrapped title (capitalised, or the parent
// ends in a stopper) — is a subtask, tested below.
import Testing
import Foundation
@testable import KronosCore

struct NoteSplitterSubtasksTests {
    private let today = Day.today()

    @Test func bulletedSubtasksUnderAPlainTaskLine() {
        let text = "Onboard Globex\n- send the contract\n- schedule the kickoff"
        let proposals = NoteSplitter.split(text, today: today)
        #expect(proposals.count == 1)
        #expect(proposals.first?.title == "Onboard Globex")
        let subtasks = NoteSplitter.subtasks(in: text)
        #expect(subtasks[proposals[0].sourceLine] == ["send the contract", "schedule the kickoff"])
    }

    /// A plain indented line under a BULLETED parent still becomes a subtask (not merged)
    /// when it does NOT read as a wrapped title continuation — here because it starts with a
    /// capital letter (NoteSplitterWrappedContinuationTests covers each of the pre-pass's own
    /// four conditions individually; this test only confirms `subtasks(in:)` reports it).
    @Test func capitalisedIndentedLineUnderABulletIsASubtaskNotATitleMerge() {
        let text = "- Write the proposal\n  Send it to the September client\n- Second task"
        let proposals = NoteSplitter.split(text, today: today)
        #expect(proposals.count == 2)
        #expect(proposals[0].title == "Write the proposal")
        let subtasks = NoteSplitter.subtasks(in: text)
        #expect(subtasks[proposals[0].sourceLine] == ["Send it to the September client"])
    }

    @Test func flatBulletListStaysAllTopLevelTasksWithNoSubtasks() {
        let text = "- Pay the invoice\n- Renew the domain\n- Call the accountant"
        let proposals = NoteSplitter.split(text, today: today)
        #expect(proposals.count == 3)
        let subtasks = NoteSplitter.subtasks(in: text)
        #expect(subtasks.isEmpty)
    }

    @Test func checkedSubtaskLinesAreSkippedEntirely() {
        let text = "Ship the release\n- [x] Write changelog\n- Tag the build"
        let proposals = NoteSplitter.split(text, today: today)
        #expect(proposals.count == 1)
        let subtasks = NoteSplitter.subtasks(in: text)
        #expect(subtasks[proposals[0].sourceLine] == ["Tag the build"])
    }

    @Test func tabIndentedSubtasksMatchTaskOutlineDirectly() {
        let text = "Ship the newsletter\n\tWrite the intro\n\tPick three links\nBook the dentist"
        let proposals = NoteSplitter.split(text, today: today)
        #expect(proposals.count == 2)
        let subtasks = NoteSplitter.subtasks(in: text)
        #expect(subtasks[proposals[0].sourceLine] == ["Write the intro", "Pick three links"])
        #expect(subtasks[proposals[1].sourceLine] == nil)
    }

    @Test func nestedBulletsTwoLevelsDeepAllBecomeOneFlatSubtaskList() {
        // Matches TaskOutlineTests.nestedBulletsBelongToTheBulletAboveThem: subtasks are a
        // flat list on the parent, not a further tree — KSubtask has no nesting of its own.
        let text = "- Launch page\n  - write copy\n  - export images\n- Send recap"
        let proposals = NoteSplitter.split(text, today: today)
        #expect(proposals.count == 2)
        let subtasks = NoteSplitter.subtasks(in: text)
        #expect(subtasks[proposals[0].sourceLine] == ["write copy", "export images"])
    }

    // MARK: `>` as a line-start bullet marker, and "Task > sub > sub" on one line. Hand-tabled
    // against NoteSplitter.bulletMarker's own doc comment and TaskOutline.split's " > " rule,
    // not derived from the code under test.

    @Test func greaterThanPrefixedLineIsASubtaskLikeADashOrStar() {
        let text = "Onboard Globex\n> send the contract\n> schedule the kickoff"
        let proposals = NoteSplitter.split(text, today: today)
        #expect(proposals.count == 1)
        #expect(proposals.first?.title == "Onboard Globex")
        let subtasks = NoteSplitter.subtasks(in: text)
        #expect(subtasks[proposals[0].sourceLine] == ["send the contract", "schedule the kickoff"])
    }

    @Test func mixedDashStarGreaterThanSubtaskMarkersAllAttachToTheSameParent() {
        let text = "Ship the release\n- write changelog\n* tag the build\n> notify the team"
        let proposals = NoteSplitter.split(text, today: today)
        #expect(proposals.count == 1)
        let subtasks = NoteSplitter.subtasks(in: text)
        #expect(subtasks[proposals[0].sourceLine] == ["write changelog", "tag the build", "notify the team"])
    }

    @Test func inlineGreaterThanChainOnOneLineSplitsIntoTaskPlusSubtasks() {
        let text = "Prepare the offer > find the template > fill in prices"
        let proposals = NoteSplitter.split(text, today: today)
        #expect(proposals.count == 1)
        #expect(proposals.first?.title == "Prepare the offer")
        let subtasks = NoteSplitter.subtasks(in: text)
        #expect(subtasks[proposals[0].sourceLine] == ["find the template", "fill in prices"])
    }

    /// A bulleted line whose own text uses the inline "a > b" chain splits too — the two
    /// mechanisms (line-start marker, inline separator) compose rather than fight.
    @Test func bulletedLineWithInlineGreaterThanChainSplitsBothWays() {
        let text = "Weekly ops\n- Prepare the offer > find the template > fill in prices"
        let proposals = NoteSplitter.split(text, today: today)
        #expect(proposals.count == 1)
        #expect(proposals.first?.title == "Weekly ops")
        let subtasks = NoteSplitter.subtasks(in: text)
        #expect(subtasks[proposals[0].sourceLine] == ["Prepare the offer", "find the template", "fill in prices"])
    }

    /// "price > 100?"-shaped text with an empty side of `>` stays one piece (TaskOutline.split's
    /// own documented guard) — a title that happens to contain a bare `>` is never mis-split.
    @Test func greaterThanWithoutSpacesOnBothSidesStaysPartOfTheTitle() {
        let text = "Check if price>100 before approving"
        let proposals = NoteSplitter.split(text, today: today)
        #expect(proposals.count == 1)
        #expect(proposals.first?.title == "Check if price>100 before approving")
        #expect(NoteSplitter.subtasks(in: text).isEmpty)
    }
}
