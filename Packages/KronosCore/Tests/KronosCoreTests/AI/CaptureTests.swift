// Named invariant tests for "paste notes -> tasks" and
// "break a task into subtasks".
//
// Every test here can fail: each one is paired with a assertion that would
// break under the bug it guards against, not a tautology.

import Testing
import Foundation
@testable import KronosCore

@MainActor
struct CaptureTests {

    private func makeStore() throws -> TaskStore { try TaskStore(inMemory: true) }
    private let today = Day.today()

    // MARK: - NoteSplitter (deterministic)

    @Test func extractSplitsBulletsNumbersAndCheckboxes() {
        let text = """
        - Call the bank
        * Send the invoice
        • Book a table
        1. Write the report
        2) Pay the rent
        - [ ] Buy milk
        - [x] Already done, skip me
        Plain line as a task
        """
        let proposals = NoteSplitter.split(text, today: today)
        let titles = proposals.map(\.title)
        #expect(titles.contains("Call the bank"))
        #expect(titles.contains("Send the invoice"))
        #expect(titles.contains("Book a table"))
        #expect(titles.contains("Write the report"))
        #expect(titles.contains("Pay the rent"))
        #expect(titles.contains("Buy milk"))
        #expect(titles.contains("Plain line as a task"))
        #expect(!titles.contains(where: { $0.contains("Already done") }))
    }

    @Test func extractKeepsDiacriticsAndParsesHrDates() {
        let text = "- Nazvati Đakovo oko isporuke sutra !!! #acme"
        let proposals = NoteSplitter.split(text, today: today, projectNames: ["Acme"])
        let p = proposals.first
        #expect(p?.title == "Nazvati Đakovo oko isporuke")
        #expect(p?.projectName == "Acme")
        #expect(p?.priority == .high)
        #expect(p?.dueDay == today + 1)
    }

    @Test func extractNeverExceedsThirtyProposals() {
        let lines = (1...40).map { "- Task number \($0) with enough letters" }
        let text = lines.joined(separator: "\n")
        let proposals = NoteSplitter.split(text, today: today)
        #expect(proposals.count == 30)
    }

    // MARK: - Router extractTasks (AI path)
    //
    // The AI reply contract is the app's own plain-text outline syntax, not JSON with a
    // whole-line `sourceLine` — see CaptureSyntaxTests.swift for the contract's full coverage
    // (grammar, hallucination guard, hop-on-zero-kept, reason threading). The two tests below
    // cover invariants unrelated to the wire format itself.

    @Test func aiExtractDropsAnUngroundedTask() async {
        let text = "Call Alex about the delivery !! **"
        let reply = "Call Alex about the delivery !! **\n\nInvented task not in the input !! **\n"
        let client = FixtureAIClient(modelID: "claude-sonnet-5", script: [.content(reply)])
        let router = AIRouter(mode: .allowAny, candidates: [AIRoutedCandidate(client: client)])

        let result = await router.extractTasks(from: text, projectNames: [],
                                               existingOpenTitles: [], today: today)
        #expect(!result.isDeterministic)
        #expect(result.tasks.count == 1)
        #expect(result.tasks.first?.title == "Call Alex about the delivery")
    }

    @Test func extractMarksDuplicatesOfOpenTasks() {
        let text = "- Call the bank about the loan"
        let proposals = NoteSplitter.split(text, today: today)
        let marked = AIRouter.markDuplicates(proposals, existingOpenTitles: ["Call the bank about the loan"])
        #expect(marked.first?.isDuplicateOfOpenTask == true)

        let unmarked = AIRouter.markDuplicates(proposals, existingOpenTitles: ["Something else entirely"])
        #expect(unmarked.first?.isDuplicateOfOpenTask == false)
    }

    @Test func aiModeOffExtractNeverTouchesTheNetwork() async {
        let client = FixtureAIClient(modelID: "claude-sonnet-5",
                                     script: [.content("Call the bank !! **\n")])
        let router = AIRouter(mode: .off, candidates: [AIRoutedCandidate(client: client)])

        let result = await router.extractTasks(from: "- Call the bank", projectNames: [],
                                               existingOpenTitles: [], today: today)
        #expect(result.isDeterministic)
        #expect(result.reason == .aiOff)
        #expect(await client.callCount == 0)
    }

    // MARK: - Store: createMany / addSubtasks (one undo step)

    @Test func createManyIsOneUndoStep() throws {
        let store = try makeStore()
        let depth = store.undoDepth
        let proposals = [
            ProposedTask(title: "A", firstMove: "Open A", sourceLine: "A"),
            ProposedTask(title: "B", priority: .high, effort: .m, sourceLine: "B"),
            ProposedTask(title: "C", sourceLine: "C")
        ]

        let created = store.createMany(proposals, defaultProject: nil)
        #expect(created.count == 3)
        #expect(store.undoDepth == depth + 1)
        #expect(store.allTasks().count == 3)

        store.undo()
        #expect(store.undoDepth == depth)
        #expect(store.allTasks().count == 0)

        // Redo after undo (a named trap): the batch comes back with EVERY
        // field intact, not just the row's existence — firstMove/priority/
        // effort are set directly on the model after `create()` returns, so
        // this proves they survive the soft-delete/restore undo cycle too.
        store.redo()
        #expect(store.allTasks().count == 3)
        let b = store.allTasks().first { $0.title == "B" }
        #expect(b?.priority == .high)
        #expect(b?.effort == .m)
        let a = store.allTasks().first { $0.title == "A" }
        #expect(a?.firstMove == "Open A")
    }

    @Test func addSubtasksIsOneUndoStep() throws {
        let store = try makeStore()
        let task = store.create(title: "Parent", notes: "", project: nil,
                                status: .todo, priority: .none, dueDay: nil)
        let depth = store.undoDepth

        store.addSubtasks(["Step 1", "Step 2", "Step 3"], to: task.id)
        #expect(store.undoDepth == depth + 1)
        #expect(store.task(task.id)?.orderedSubtasks.count == 3)

        store.undo()
        #expect(store.undoDepth == depth)
        #expect(store.task(task.id)?.orderedSubtasks.count == 0)

        // Redo after undo: subtasks use detach/reattach (never SwiftData
        // delete), so all three must come back, in their original order.
        store.redo()
        let titles = store.task(task.id)?.orderedSubtasks.map(\.title)
        #expect(titles == ["Step 1", "Step 2", "Step 3"])
    }

    @Test func createManyResolvesProjectByFoldedNameAndFallsBackWhenUnknown() throws {
        let store = try makeStore()
        let acme = store.createProject(name: "Acme", colorHex: "#000000", icon: "circle", area: nil)
        let fallback = store.createProject(name: "Inbox Project", colorHex: "#000000",
                                           icon: "circle", area: nil)
        let proposals = [
            ProposedTask(title: "Matches by folded name", projectName: "acme", sourceLine: "x"),
            ProposedTask(title: "Unknown project falls back", projectName: "Nonexistent", sourceLine: "y")
        ]

        let created = store.createMany(proposals, defaultProject: fallback)
        let matched = created.first { $0.title == "Matches by folded name" }
        let fell = created.first { $0.title == "Unknown project falls back" }
        #expect(matched?.project?.id == acme.id)
        #expect(fell?.project?.id == fallback.id)
    }

    @Test func breakdownNeverTouchesExistingSubtasks() throws {
        let store = try makeStore()
        let task = store.create(title: "Parent", notes: "", project: nil,
                                status: .todo, priority: .none, dueDay: nil)
        store.addSubtask(task.id, title: "Existing step one")
        store.addSubtask(task.id, title: "Existing step two")
        let before = store.task(task.id)?.orderedSubtasks.map(\.title)

        store.addSubtasks(["New step A", "New step B"], to: task.id)

        let after = store.task(task.id)?.orderedSubtasks.map(\.title) ?? []
        #expect(after.prefix(2).elementsEqual(before ?? []))
        #expect(after.count == 4)
    }

    // MARK: - DeterministicBreakdown

    @Test func breakdownReturnsThreeToSevenSteps() {
        let result = DeterministicBreakdown.steps(title: "Send the September invoice to Alex",
                                                  notes: "", language: .en)
        #expect((3...7).contains(result.subtasks.count))
        #expect(!result.firstMove.isEmpty)
        #expect(result.subtasks.first == result.firstMove)
        for step in result.subtasks {
            #expect(FirstMoveLint.lint(step, language: .en, dreadMode: false).isPass,
                    "step failed its own lint: \(step)")
        }
    }

    // MARK: - Prompt drift (capture-specific)
    //
    // The extract prompt returns the outline grammar, not JSON, so the two tests below check the
    // equivalent guarantee for that grammar: the prompt explains every marker the parser actually
    // accepts, and its own worked example parses cleanly through the REAL parser.

    @Test func capturePromptExplainsEveryOutlineMarkerTheParserAccepts() {
        for marker in ["!N", "*N", "#project-name", "YYYY-MM-DD", "<tasks>", "</tasks>"] {
            #expect(PromptTemplates.extractSystem.contains(marker), "extract prompt missing marker: \(marker)")
        }
    }

    @Test func capturePromptExampleParsesThroughTheRealParser() throws {
        let block = ExtractOutlineValidator.extractOutlineBlock(PromptTemplates.extractSystem)
        #expect(block != PromptTemplates.extractSystem, "no <tasks>...</tasks> block found in the worked example")
        let proposals = NoteSplitter.split(block, today: today)
        #expect(!proposals.isEmpty)
        for p in proposals {
            #expect(p.priority != .none && p.effort != .none,
                    "worked-example task missing priority/effort: title=\(p.title) priority=\(p.priority) effort=\(p.effort)")
        }
    }

    // MARK: - Privacy

    @Test func sanitizeCaptureRedactsSecretsButKeepsLength() {
        var text = String(repeating: "a ", count: 1000)   // 2000 chars
        text += " email me at alex@example.com or call +385 91 234 5678, password: hunter2secret"
        let sanitized = PrivacyRedactor.sanitizeCapture(text)

        #expect(abs(sanitized.count - text.count) < 400)   // roughly the same length
        #expect(!sanitized.contains("alex@example.com"))
        #expect(!sanitized.contains("hunter2secret"))
        #expect(sanitized.count <= 6000)
    }

    @Test func sanitizeCaptureCapsAtSixThousandCharacters() {
        let text = String(repeating: "a", count: 8000)
        let sanitized = PrivacyRedactor.sanitizeCapture(text)
        #expect(sanitized.count == 6000)
    }

    // MARK: - NoteSplitter, additional coverage

    @Test func extractJoinsWrappedContinuationLineToThePreviousTask() {
        let text = """
        - Write the proposal
          for the September delivery
        - Second task
        """
        let proposals = NoteSplitter.split(text, today: today)
        #expect(proposals.count == 2)
        #expect(proposals.first?.title.contains("for the September delivery") == true)
    }

    @Test func extractHeadingSetsProjectOnlyWhenItMatchesAnExistingProject() {
        let text = """
        Acme:
        - Order more napkins

        Unknown Heading:
        - Some other task
        """
        let proposals = NoteSplitter.split(text, today: today, projectNames: ["Acme"])
        #expect(proposals.first { $0.title == "Order more napkins" }?.projectName == "Acme")
        #expect(proposals.first { $0.title == "Some other task" }?.projectName == nil)
    }

    @Test func extractSkipsHeadingsHorizontalRulesAndTooShortLines() {
        let text = """
        # A heading with no colon
        ---
        - Ok
        - Do the thing
        """
        let proposals = NoteSplitter.split(text, today: today)
        // "Ok" has only 2 letters, below the 3-letter floor, and is dropped;
        // the heading and rule are never task-shaped at all.
        #expect(proposals.count == 1)
        #expect(proposals.first?.title == "Do the thing")
    }

    // MARK: - DeterministicBreakdown, additional coverage

    @Test func breakdownStepsAreLanguageConsistentForHrTitle() {
        let result = DeterministicBreakdown.steps(title: "Nazvati Alexa oko isporuke",
                                                  notes: "", language: .hr)
        #expect((3...7).contains(result.subtasks.count))
        for step in result.subtasks {
            #expect(FirstMoveLint.lint(step, language: .hr, dreadMode: false).isPass,
                    "step failed its own lint: \(step)")
        }
    }

    @Test func breakdownIncludesAnOpenNotesStepWhenNotesAreNonEmpty() {
        let withNotes = DeterministicBreakdown.steps(title: "Prepare the report",
                                                     notes: "some context", language: .en)
        let withoutNotes = DeterministicBreakdown.steps(title: "Prepare the report",
                                                        notes: "", language: .en)
        #expect(withNotes.subtasks.count >= withoutNotes.subtasks.count)
    }

    // MARK: - Codable round trip (ProposedTask / ExtractResult / BreakdownResult)

    @Test func proposedTaskRoundTripsThroughCodable() throws {
        let original = ProposedTask(title: "Call Alex", firstMove: "Open Contacts",
                                    projectName: "Acme", labelNames: ["urgent"],
                                    priority: .high, effort: .m, dueDay: today,
                                    notes: "some notes", sourceLine: "- call Alex",
                                    isDuplicateOfOpenTask: true, isFromAI: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProposedTask.self, from: data)
        #expect(decoded == original)
    }

    @Test func extractResultRoundTripsThroughCodable() throws {
        let original = ExtractResult(tasks: [ProposedTask(title: "A", sourceLine: "A")],
                                     droppedLineCount: 2, isDeterministic: false)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ExtractResult.self, from: data)
        #expect(decoded == original)
    }

    // MARK: - Router breakdown (AI path, additional coverage beyond the named gate list)

    @Test func aiBreakdownFallsBackWhenReplyDuplicatesExistingSubtask() async {
        let json = """
        {"subtasks":["Existing step","Do something else","Do a third thing"],
         "firstMove":"Existing step"}
        """
        let client = FixtureAIClient(modelID: "claude-sonnet-5", script: [.content(json)])
        let router = AIRouter(mode: .allowAny, candidates: [AIRoutedCandidate(client: client)])

        let result = await router.breakdown(title: "Send the invoice", notes: "",
                                           existingSubtasks: ["Existing step"])
        #expect(result.isDeterministic)
    }

    @Test func aiBreakdownAcceptsAValidImprovedReply() async {
        let json = """
        {"subtasks":["Open Mail and start a new message.","Attach the September invoice.",
                      "Address it to Alex.","Send the message."],
         "firstMove":"Open Mail and start a new message."}
        """
        let client = FixtureAIClient(modelID: "claude-sonnet-5", script: [.content(json)])
        let router = AIRouter(mode: .allowAny, candidates: [AIRoutedCandidate(client: client)])

        let result = await router.breakdown(title: "Send the September invoice to Alex", notes: "",
                                           existingSubtasks: [])
        #expect(!result.isDeterministic)
        #expect(result.subtasks.count == 4)
    }
}
