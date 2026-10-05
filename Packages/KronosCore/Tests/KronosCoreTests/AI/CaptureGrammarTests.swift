// CaptureGrammar: the shapes a person actually types into Capture. Every expectation is a
// hand-written table, never derived from the code under test.
import Testing
import Foundation
@testable import KronosCore

struct CaptureGrammarTests {
    private let today = Day.today()

    private struct Shape: Equatable, CustomStringConvertible {
        var title: String
        var subs: [String]
        var description: String { "\(title) \(subs)" }
        init(_ title: String, _ subs: [String] = []) { self.title = title; self.subs = subs }
    }

    private func shapes(_ text: String, projects: [String] = []) -> [Shape] {
        CaptureGrammar.parse(text, today: today, projectNames: projects).items.map { Shape($0.proposal.title, $0.subtasks) }
    }

    // MARK: plain lines and blank lines

    @Test func plainLinesAreSeparateTasks() {
        #expect(shapes("Kupiti mlijeko\nNazvati mamu\nPoslati račun") ==
                [Shape("Kupiti mlijeko"), Shape("Nazvati mamu"), Shape("Poslati račun")])
    }

    @Test func lowercaseAndPeriodTerminatedLinesAreStillTasks() {
        #expect(shapes("kupiti mlijeko\nnazvati mamu.\nposlati račun!") ==
                [Shape("kupiti mlijeko"), Shape("nazvati mamu."), Shape("poslati račun!")])
    }

    @Test func oneAndTwoBlankLinesBetweenTasks() {
        #expect(shapes("Task one\n\nTask two\n\n\nTask three") ==
                [Shape("Task one"), Shape("Task two"), Shape("Task three")])
    }

    @Test func blankLinesAroundIndentedSubtasksKeepStructure() {
        let text = "Task A\n    sub a1\n    sub a2\n\nTask B\n    sub b1\n\n\nTask C"
        #expect(shapes(text) == [Shape("Task A", ["sub a1", "sub a2"]), Shape("Task B", ["sub b1"]), Shape("Task C")])
    }

    @Test func blankLineBetweenSameLevelBulletsKeepsTasks() {
        #expect(shapes("- Alpha\n\n- Beta") == [Shape("Alpha"), Shape("Beta")])
    }

    @Test func blankLineEndsAGroupSoNextPlainLineIsANewTask() {
        #expect(shapes("Task A\n- x\n\nTask B\n- y") == [Shape("Task A", ["x"]), Shape("Task B", ["y"])])
    }

    @Test func windowsLineEndings() {
        #expect(shapes("One task\r\nTwo task\r\n  sub") == [Shape("One task"), Shape("Two task", ["sub"])])
    }

    // MARK: subtasks

    @Test(arguments: [
        ("Parent\n\tchild", "tab"),
        ("Parent\n  child", "2 spaces"),
        ("Parent\n    child", "4 spaces"),
        ("Parent\n- child", "dash"),
        ("Parent\n* child", "star"),
        ("Parent\n• child", "bullet dot"),
        ("Parent\n> child", "greater-than"),
        ("Parent\n  - child", "indented dash"),
        ("Parent\n\t> child", "indented greater-than"),
        ("Parent > child", "inline"),
    ])
    func subtaskForms(text: String, label: String) {
        #expect(shapes(text) == [Shape("Parent", ["child"])], Comment(rawValue: label))
    }

    @Test func severalSubtasksAndTwoParents() {
        let text = "Plan trip\n- book flights\n- book hotel\nPack\n  passport\n  charger"
        #expect(shapes(text) == [Shape("Plan trip", ["book flights", "book hotel"]),
                                 Shape("Pack", ["passport", "charger"])])
    }

    @Test func lowercaseSubtaskUnderABulletedParentStaysASubtask() {
        #expect(shapes("- Prepare offer\n  find template\n- Send offer") ==
                [Shape("Prepare offer", ["find template"]), Shape("Send offer")])
    }

    @Test func greaterThanUnderABulletedParentIsASubtask() {
        #expect(shapes("- Parent\n> child") == [Shape("Parent", ["child"])])
    }

    @Test func nestedDeeperLevelsFlattenIntoTheTopTask() {
        #expect(shapes("Top\n  mid\n    low") == [Shape("Top", ["mid", "low"])])
    }

    @Test func dashSubtasksUnderANumberedParent() {
        #expect(shapes("1. Parent\n- child\n2. Next") == [Shape("Parent", ["child"]), Shape("Next")])
    }

    @Test func sameLevelBulletListStaysTasks() {
        #expect(shapes("- one task\n- two task\n- three task") ==
                [Shape("one task"), Shape("two task"), Shape("three task")])
    }

    @Test func numberedListsAreTasks() {
        #expect(shapes("1. First thing\n2. Second thing\n3) Third thing") ==
                [Shape("First thing"), Shape("Second thing"), Shape("Third thing")])
    }

    @Test func numberedTasksWithIndentedSubtasks() {
        #expect(shapes("1. First\n   a\n   b\n2. Second") == [Shape("First", ["a", "b"]), Shape("Second")])
    }

    @Test func dedentStartsANewTask() {
        #expect(shapes("AA\n  a1\nBB") == [Shape("AA", ["a1"]), Shape("BB")])
    }

    // MARK: identity, short titles, drops

    @Test func duplicateTitlesKeepTheirOwnSubtasks() {
        let outline = CaptureGrammar.parse("Pay bill\n- first\n\nPay bill\n- second", today: today)
        #expect(outline.items.count == 2)
        #expect(outline.items[0].subtasks == ["first"])
        #expect(outline.items[1].subtasks == ["second"])
        #expect(outline.items.map(\.lineIndex) == [0, 3])
    }

    @Test func shortTitlesSurvive() {
        #expect(shapes("Pay\nGo\nCV") == [Shape("Pay"), Shape("Go"), Shape("CV")])
        #expect(shapes("- Ok\n- Go") == [Shape("Ok"), Shape("Go")])
    }

    @Test func oneCharacterLineIsReportedNotSilentlyDropped() {
        let outline = CaptureGrammar.parse("Pay\nA\nGo", today: today)
        #expect(outline.items.map(\.proposal.title) == ["Pay", "Go"])
        #expect(outline.dropped == [DroppedLine(text: "A", lineIndex: 1, reason: .tooShort)])
    }

    @Test func tickedBoxesAreSkippedAndReported() {
        let outline = CaptureGrammar.parse("- [ ] Buy milk\n- [x] Done already", today: today)
        #expect(outline.items.map(\.proposal.title) == ["Buy milk"])
        #expect(outline.dropped.map(\.reason) == [.done])
    }

    @Test func overTheCapIsCountedNeverSilent() {
        let text = (1...105).map { "Task number \($0)" }.joined(separator: "\n")
        let outline = CaptureGrammar.parse(text, today: today)
        #expect(outline.items.count == 100)
        #expect(outline.overflow == 5)
        #expect(outline.dropped.filter { $0.reason == .overCap }.count == 5)
    }

    @Test func subtasksOfACappedTaskAreNotGluedToTheLastKeptTask() {
        let text = (1...100).map { "Task \($0)" }.joined(separator: "\n") + "\nExtra\n  hidden sub"
        let outline = CaptureGrammar.parse(text, today: today)
        #expect(outline.items.last?.subtasks == [])
        #expect(outline.overflow == 1)
    }

    // MARK: headings and notes

    @Test func colonLineWithBulletsIsATaskWithSubtasks() {
        #expect(shapes("Shopping:\n- milk\n- eggs") == [Shape("Shopping", ["milk", "eggs"])])
    }

    @Test func colonLineNamingAProjectIsAHeading() {
        let outline = CaptureGrammar.parse("Acme:\n- Call Alex\n- Send invoice", today: today, projectNames: ["Acme"])
        #expect(outline.items.map(\.proposal.title) == ["Call Alex", "Send invoice"])
        #expect(outline.items.map(\.proposal.projectName) == ["Acme", "Acme"])
    }

    @Test func twoBlankLinesForgetTheHeadingProject() {
        let outline = CaptureGrammar.parse("Acme:\n- Call Alex\n\n\n- Buy milk", today: today, projectNames: ["Acme"])
        #expect(outline.items.map(\.proposal.projectName) == ["Acme", nil])
    }

    @Test func markdownHeadingIsNeverATask() {
        #expect(shapes("# Weekend\nMow the lawn") == [Shape("Mow the lawn")])
    }

    @Test func explicitNoteMarkers() {
        let outline = CaptureGrammar.parse("Call Alex\n// he prefers mail\nnote: ask about the PDF\nNext", today: today)
        #expect(outline.items.map(\.proposal.title) == ["Call Alex", "Next"])
        #expect(outline.items[0].proposal.notes == "he prefers mail\nask about the PDF")
    }

    @Test func tokensStillParse() {
        let outline = CaptureGrammar.parse("- Nazvati Đakovo sutra !!! #acme", today: today, projectNames: ["Acme"])
        let p = outline.items.first?.proposal
        #expect(p?.title == "Nazvati Đakovo")
        #expect(p?.projectName == "Acme")
        #expect(p?.priority == .high)
        #expect(p?.dueDay == today + 1)
    }

    // MARK: prose

    @Test func shortListIsNotProse() {
        #expect(!CaptureGrammar.parse("Pay\nGo\nCall Alex", today: today).looksLikeProse)
    }

    @Test func multiSentenceLineIsProseWithFirstSentenceTitle() {
        let outline = CaptureGrammar.parse("Call Alex about the invoice. He asked for the PDF version.", today: today)
        #expect(outline.looksLikeProse)
        #expect(outline.items.count == 1)
        #expect(outline.items[0].proposal.title == "Call Alex about the invoice.")
        #expect(outline.items[0].proposal.notes == "He asked for the PDF version.")
    }

    @Test func longParagraphWithoutBoundaryIsProseAndOneTask() {
        let text = "I need to call Alex tomorrow and also send the contract, then book the venue for the party and tell everybody about the new time"
        let outline = CaptureGrammar.parse(text, today: today)
        #expect(outline.looksLikeProse)
        #expect(outline.items.count == 1)
    }

    // MARK: AI path (FixtureAIClient) and the plain-line fallback

    @Test func proseGoesThroughTheAIRouterWhenAIIsOn() async {
        let text = "I need to call Alex tomorrow and also send the contract, then book the venue."
        let reply = "1. Call Alex !! *\n\n2. Send the contract !! *\n\n3. Book the venue !! *\n"
        let client = FixtureAIClient(modelID: "claude-sonnet-5", script: [.content(reply)])
        let router = AIRouter(mode: .allowAny, candidates: [AIRoutedCandidate(client: client)])
        let result = await router.extractTasks(from: text, projectNames: [], existingOpenTitles: [], today: today)
        #expect(!result.isDeterministic)
        #expect(result.tasks.map(\.title) == ["Call Alex", "Send the contract", "Book the venue"])
        #expect(await client.callCount == 1)
    }

    @Test func proseFallsBackToThePlainLineResultWhenAIIsOff() async {
        let text = "Call Alex about the invoice. He asked for the PDF."
        let client = FixtureAIClient(modelID: "claude-sonnet-5", script: [.content("1. Nope !! *")])
        let router = AIRouter(mode: .off, candidates: [AIRoutedCandidate(client: client)])
        let result = await router.extractTasks(from: text, projectNames: [], existingOpenTitles: [], today: today)
        #expect(result.isDeterministic)
        #expect(result.reason == .aiOff)
        #expect(result.tasks.map(\.title) == ["Call Alex about the invoice."])
        #expect(await client.callCount == 0)
    }

    @Test func plainLinesFallBackWithSubtasksWhenAIIsOff() async {
        let text = "Pay\nPlan trip\n- flights\n- hotel"
        let router = AIRouter(mode: .off, candidates: [])
        let result = await router.extractTasks(from: text, projectNames: [], existingOpenTitles: [], today: today)
        #expect(result.tasks.map(\.title) == ["Pay", "Plan trip"])
        #expect(result.tasks[1].subtasks == ["flights", "hotel"])
    }

    @Test func aiReplyMissingAMarkerKeepsTheTask() async {
        let text = "Call Alex about the delivery"
        let client = FixtureAIClient(modelID: "claude-sonnet-5", script: [.content("1. Call Alex about the delivery !!\n")])
        let router = AIRouter(mode: .allowAny, candidates: [AIRoutedCandidate(client: client)])
        let result = await router.extractTasks(from: text, projectNames: [], existingOpenTitles: [], today: today)
        #expect(!result.isDeterministic)
        #expect(result.tasks.first?.effort == KEffort.none)
    }
}
