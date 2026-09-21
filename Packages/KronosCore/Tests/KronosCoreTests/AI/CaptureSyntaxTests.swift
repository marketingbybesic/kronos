// Proves the AI extract path answers in the app's own outline syntax (the same grammar
// NoteSplitter/TaskOutline/QuickAddParser already give quick add and Capture's deterministic
// pass), never JSON, never a `sourceLine` field.
//
// Every test here can fail: each is paired with an assertion that breaks under the bug it
// guards against, not a tautology.

import Testing
import Foundation
@testable import KronosCore

@MainActor
struct CaptureSyntaxTests {

    private let today = Day.today()
    private let ownerInput = "Call Alex about the invoice. He asked for the PDF version, not the scan."

    // MARK: - 1. The old JSON validator matched `sourceLine` against a whole-line source split,
    // so a multi-sentence paragraph (one "line") quoting only its first sentence back as
    // `sourceLine` never matched — `validateExtract` returned `[]`, a SUCCESSFUL, non-throwing
    // decode, so `hopAcrossModels` never hopped and `extractTasks` returned `isDeterministic:
    // false` with an EMPTY tasks array. That is worse than falling back to the deterministic
    // split, since `CaptureReviewList`'s status line had no branch for `!isDeterministic &&
    // tasks.isEmpty` and rendered nothing at all. Test 2 below runs the same scenario through the
    // fixed code, end to end.

    // MARK: - 2. The outline-syntax contract, end to end through `extractTasks`.

    @Test func ownersExactPasteGetsATaskWithNotesPriorityAndEffortThroughTheRouter() async {
        let reply = "Call Alex about the invoice !! **\nHe asked for the PDF version, not the scan.\n"
        let client = FixtureAIClient(modelID: "claude-sonnet-5", script: [.content(reply)])
        let router = AIRouter(mode: .allowAny, candidates: [AIRoutedCandidate(client: client)])

        let result = await router.extractTasks(from: ownerInput, projectNames: [],
                                                existingOpenTitles: [], today: today)
        #expect(!result.isDeterministic)
        #expect(result.tasks.count == 1)
        let t = result.tasks.first
        #expect(t?.title == "Call Alex about the invoice")
        #expect(t?.priority == .medium)
        #expect(t?.effort == .m)
        #expect(t?.notes?.contains("PDF") == true)
        if case .ai(let model) = result.reason { #expect(model == "claude-sonnet-5") }
        else { Issue.record("expected .ai(model:), got \(result.reason)") }
    }

    // MARK: - 3. extractOutlineBlock: the prompt's OWN worked example broke the naive first-
    // `<tasks>`/first-`</tasks>` extraction — see AIRouter+Capture.swift's doc comment on
    // `extractOutlineBlock`. A model that echoes its instructions before answering (small/free
    // models do this) must not have that echoed prose sliced out instead of the real answer.

    @Test func extractOutlineBlockSkipsAnEchoedInstructionBeforeTheRealAnswer() {
        let reply = """
        Sure, I will answer between <tasks> and </tasks> tags.
        <tasks>
        Call Alex about the invoice !! **
        </tasks>
        """
        let block = ExtractOutlineValidator.extractOutlineBlock(reply)
        #expect(block.trimmingCharacters(in: .whitespacesAndNewlines) == "Call Alex about the invoice !! **")
    }

    @Test func extractOutlineBlockFallsBackToTheWholeReplyWhenNoTagsArePresent() {
        let reply = "Call Alex about the invoice !! **\n"
        #expect(ExtractOutlineValidator.extractOutlineBlock(reply) == "Call Alex about the invoice !! **")
    }

    // MARK: - 4. The new outline-syntax contract at the validator level (isolated, no router)

    @Test func outlineSyntaxKeepsAParagraphTaskWithNotesPriorityAndEffort() throws {
        let reply = "Call Alex about the invoice !! **\nHe asked for the PDF version, not the scan.\n"
        let tasks = try ExtractOutlineValidator.validateExtractOutline(reply, sourceText: ownerInput,
                                                         projectNames: [], today: today)
        #expect(tasks.count == 1)
        let t = try #require(tasks.first)
        #expect(t.title == "Call Alex about the invoice")
        #expect(t.priority == .medium)
        #expect(t.effort == .m)
        #expect(t.notes?.contains("PDF") == true)
    }

    /// `CaptureModel.upgrade(with:)` (Kronos/Capture/CaptureModel.swift, app target, not
    /// reachable from KronosCore tests) matches an AI proposal back onto the deterministic
    /// pass's row by CONTAINMENT of `sourceLine`, never by the model's own outline text — this
    /// proves the CONTRACT that match depends on: the AI proposal's `sourceLine`, after
    /// validation, must equal (or be contained by) the ORIGINAL pasted line the deterministic
    /// pass used, not the model's rewritten outline line. Without the re-pointing in
    /// `validateExtractOutline`, this would be "Call Alex about the invoice !! **" (the model's
    /// own line) and would never match the app's deterministic row for the pasted input.
    @Test func outlineSyntaxSourceLineIsRepointedToTheOriginalPastedLineNotTheModelsOutlineLine() throws {
        let reply = "Call Alex about the invoice !! **\nHe asked for the PDF version, not the scan.\n"
        let tasks = try ExtractOutlineValidator.validateExtractOutline(reply, sourceText: ownerInput,
                                                         projectNames: [], today: today)
        let t = try #require(tasks.first)
        #expect(t.sourceLine == ownerInput, "sourceLine must be the ORIGINAL pasted line, not the model's own outline text")
        // The deterministic pass's own row for the same paste — same sourceLine the app has
        // always used, unaffected by the outline-syntax rewrite.
        let deterministicSourceLine = NoteSplitter.split(ownerInput, today: today).first?.sourceLine
        #expect(KTextFold.fold(t.sourceLine).contains(KTextFold.fold(deterministicSourceLine ?? "")))
    }

    // The prompt REQUIRES a sequence number ("1. ", "2. ", …) on every top-level task line
    // (structural defence against a repetitive list losing its blank-line separators — see
    // PromptTemplates.extractSystem's own "N. is a plain sequence number" rule). This proves
    // the number is stripped and never leaks into the title, on a single numbered task and on
    // consecutive numbered tasks with no blank line between them (the shape a real bulk-list
    // reply uses).
    @Test func outlineSyntaxStripsTheSequenceNumberAndNeverLeavesItInTheTitle() throws {
        let source = "Call Alex about the invoice."
        let reply = "1. Call Alex about the invoice !! *\n"
        let tasks = try ExtractOutlineValidator.validateExtractOutline(reply, sourceText: source, projectNames: [], today: today)
        #expect(tasks.count == 1)
        #expect(tasks.first?.title == "Call Alex about the invoice")
        #expect(tasks.first?.title.contains("1.") == false)
    }

    @Test func outlineSyntaxConsecutiveNumberedTasksWithNoBlankLineStayDistinctAndUnnumbered() throws {
        let source = "Task number 1 with enough letters. Task number 2 with enough letters. Task number 3 with enough letters."
        let reply = """
        1. Task number 1 with enough letters ! *
        2. Task number 2 with enough letters ! *
        3. Task number 3 with enough letters ! *
        """
        let tasks = try ExtractOutlineValidator.validateExtractOutline(reply, sourceText: source, projectNames: [], today: today)
        #expect(tasks.count == 3)
        let titles = tasks.map(\.title)
        #expect(titles == ["Task number 1 with enough letters", "Task number 2 with enough letters", "Task number 3 with enough letters"])
        for title in titles {
            #expect(!title.hasPrefix("1."), "title must not start with a leftover sequence number: \(title)")
            #expect(!title.hasPrefix("2."))
            #expect(!title.hasPrefix("3."))
        }
    }

    @Test func outlineSyntaxParsesMultipleTasksWithSubtasksAndDates() throws {
        let source = """
        Ship the release
          - write changelog
          - tag the build
        Book flight to the offsite
        """
        let reply = """
        Ship the release !!! ***
          - write changelog
          - tag the build

        Book flight to the offsite ! * 2026-09-25
        """
        let tasks = try ExtractOutlineValidator.validateExtractOutline(reply, sourceText: source, projectNames: [], today: today)
        #expect(tasks.count == 2)
        let ship = try #require(tasks.first { $0.title == "Ship the release" })
        #expect(ship.priority == .high)
        #expect(ship.effort == .l)
        #expect(ship.subtasks == ["write changelog", "tag the build"])
        let flight = try #require(tasks.first { $0.title == "Book flight to the offsite" })
        #expect(flight.priority == .low)
        #expect(flight.effort == .s)   // `*` (one star) is small, not extra-small — no bare-star xs exists.
        #expect(flight.dueDay == Day.parseISO("2026-09-25"))
    }

    // MARK: - 5. Every task line MUST carry priority and effort — leaving them unset defeats the
    // point of extraction, since the app's core workflow depends on both being set at capture
    // time. A line missing either marker is dropped, not silently accepted with `.none`, so a
    // validator that starts ignoring the requirement fails loudly here.

    @Test func outlineSyntaxRequiresBothPriorityAndEffortMarkers() throws {
        // Both lines fail the requirement (first missing effort, second missing priority), so
        // BOTH are dropped and zero survive — `validateExtractOutline` throws on zero kept
        // (section 6, below), which is itself the proof neither was kept with a `.none` default.
        let source = "Buy milk\nCall the bank"
        let reply = "Buy milk !\n\nCall the bank *\n"
        #expect(throws: (any Error).self) {
            _ = try ExtractOutlineValidator.validateExtractOutline(reply, sourceText: source, projectNames: [], today: today)
        }
    }

    @Test func outlineSyntaxDropsOnlyTheLineMissingAMarkerKeepsItsSibling() throws {
        let source = "Buy milk\nCall the bank about the loan"
        // Blank line between them is REQUIRED by the grammar (a plain line right after a task
        // line is read as ITS notes, not a new task) — without it "Call the bank..." would be
        // absorbed into "Buy milk"'s notes instead of becoming its own task line.
        let reply = "Buy milk !\n\nCall the bank about the loan !! **\n"   // first missing effort
        let tasks = try ExtractOutlineValidator.validateExtractOutline(reply, sourceText: source, projectNames: [], today: today)
        #expect(tasks.count == 1)
        #expect(tasks.first?.title == "Call the bank about the loan")
    }

    // MARK: - 6. Hallucination guard: title content words must ground in the source, OR notes
    // must be a verbatim substring. Replaces the old whole-line `sourceLine` rule.

    @Test func hallucinationGuardDropsATaskNotGroundedInTheSource() throws {
        let source = "Call Alex about the invoice."
        let reply = "Schedule a trip to the moon !! **\n"   // shares no content words with source
        #expect(throws: (any Error).self) {
            _ = try ExtractOutlineValidator.validateExtractOutline(reply, sourceText: source, projectNames: [], today: today)
        }
    }

    @Test func hallucinationGuardKeepsATaskWhoseNotesAreAVerbatimSubstring() throws {
        let source = "Random heading\nHe asked for the PDF version, not the scan, urgently."
        // Notes sit at the SAME indent as the task line, per the grammar (an indented line is a
        // subtask, never notes) — NoteSplitterNotesTests already covers this for the deterministic path.
        let reply = "Get the file !! **\nHe asked for the PDF version, not the scan, urgently.\n"
        let tasks = try ExtractOutlineValidator.validateExtractOutline(reply, sourceText: source, projectNames: [], today: today)
        #expect(tasks.count == 1, "notes verbatim in the source is enough to keep the task even if the title shares few words")
    }

    // MARK: - 7. Zero kept tasks THROWS (does not silently succeed with an empty array) so
    // `hopAcrossModels` tries the next candidate — AIRouter+Capture.swift's old `catch` was
    // unreachable for an empty-but-valid reply, so a model reply that kept nothing looked
    // identical to a model reply that succeeded with nothing to say.

    @Test func zeroKeptTasksThrowsInsteadOfReturningEmptySuccess() {
        let reply = "Totally unrelated nonsense !! **\n"
        #expect(throws: (any Error).self) {
            _ = try ExtractOutlineValidator.validateExtractOutline(reply, sourceText: "Call Alex about the invoice.",
                                                     projectNames: [], today: today)
        }
    }

    @Test func emptyModelAnswerThrows() {
        #expect(throws: (any Error).self) {
            _ = try ExtractOutlineValidator.validateExtractOutline("", sourceText: "Call Alex about the invoice.",
                                                     projectNames: [], today: today)
        }
    }

    // MARK: - 8. hopAcrossModels actually hops when the first candidate's reply keeps zero tasks
    // (proves the router-level wiring, not just the validator in isolation).

    @Test func extractHopsToFallbackModelWhenFirstCandidateKeepsNothing() async {
        let text = ownerInput
        let firstReply = "Totally unrelated nonsense !! **\n"   // grounds in nothing -> validator throws
        let secondReply = "Call Alex about the invoice !! **\nHe asked for the PDF version, not the scan.\n"
        let first = FixtureAIClient(modelID: "model-a", script: [.content(firstReply)])
        let second = FixtureAIClient(modelID: "model-b", script: [.content(secondReply)])
        let router = AIRouter(mode: .allowAny, candidates: [
            AIRoutedCandidate(client: first), AIRoutedCandidate(client: second)
        ])

        let result = await router.extractTasks(from: text, projectNames: [], existingOpenTitles: [], today: today)
        #expect(!result.isDeterministic)
        #expect(result.tasks.count == 1)
        #expect(result.tasks.first?.title == "Call Alex about the invoice")
        #expect(await first.callCount == 1)
        #expect(await second.callCount == 1)
    }

    // MARK: - 9. NOTHING SILENT: when every candidate fails, `extractTasks` returns the
    // deterministic result carrying a REASON, never a bare `isDeterministic` flag with no story.

    @Test func allCandidatesRejectedReturnsDeterministicWithAllRejectedReason() async {
        let text = ownerInput
        let badReply = "Totally unrelated nonsense !! **\n"
        let client = FixtureAIClient(modelID: "model-a", script: [.content(badReply)])
        let router = AIRouter(mode: .allowAny, candidates: [AIRoutedCandidate(client: client)])

        let result = await router.extractTasks(from: text, projectNames: [], existingOpenTitles: [], today: today)
        #expect(result.isDeterministic)
        if case .allRejected(let n) = result.reason { #expect(n >= 1) }
        else { Issue.record("expected .allRejected, got \(result.reason)") }
    }

    @Test func aiOffReasonIsAiOff() async {
        let client = FixtureAIClient(modelID: "model-a", script: [.content("irrelevant")])
        let router = AIRouter(mode: .off, candidates: [AIRoutedCandidate(client: client)])
        let result = await router.extractTasks(from: ownerInput, projectNames: [], existingOpenTitles: [], today: today)
        #expect(result.reason == .aiOff)
    }

    @Test func noModelConfiguredReasonIsNoModel() async {
        let router = AIRouter(mode: .allowAny, candidates: [])
        let result = await router.extractTasks(from: ownerInput, projectNames: [], existingOpenTitles: [], today: today)
        #expect(result.reason == .noModel)
    }

    @Test func transportFailureReasonCarriesTheError() async {
        let client = FixtureAIClient(modelID: "model-a", script: [.failure(.http(500))])
        let router = AIRouter(mode: .allowAny, candidates: [AIRoutedCandidate(client: client)])
        let result = await router.extractTasks(from: ownerInput, projectNames: [], existingOpenTitles: [], today: today)
        #expect(result.isDeterministic)
        if case .transport = result.reason {} else { Issue.record("expected .transport, got \(result.reason)") }
    }

    // MARK: - 10. Deterministic path (AI off): a single multi-sentence paragraph -> first
    // sentence is the title, the rest becomes notes, instead of the whole paragraph as the title.

    @Test func deterministicSplitParagraphFirstSentenceIsTitleRestIsNotes() {
        let proposals = NoteSplitter.split(ownerInput, today: today)
        #expect(proposals.count == 1)
        let p = try? #require(proposals.first)
        #expect(p?.title == "Call Alex about the invoice.")
        let notes = NoteSplitter.notes(in: ownerInput)
        #expect(notes[p?.sourceLine ?? ""]?.contains("PDF version") == true)
    }

    @Test func deterministicSplitSingleSentenceParagraphHasNoNotes() {
        let text = "Call the bank about the loan."
        let proposals = NoteSplitter.split(text, today: today)
        #expect(proposals.count == 1)
        #expect(proposals.first?.title == "Call the bank about the loan.")
        let notes = NoteSplitter.notes(in: text)
        #expect(notes.isEmpty)
    }

    @Test func deterministicSplitBulletedInputIsUnaffectedByTheParagraphRule() {
        // Regression guard: the paragraph rule must only apply to a plain (unbulleted) line
        // with more than one sentence — a bulleted list keeps behaving exactly as before.
        let text = "- Call the bank\n- Send the invoice"
        let proposals = NoteSplitter.split(text, today: today)
        #expect(proposals.map(\.title) == ["Call the bank", "Send the invoice"])
    }
}
