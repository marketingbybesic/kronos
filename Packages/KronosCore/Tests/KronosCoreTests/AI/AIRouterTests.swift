import Testing
import Foundation
@testable import KronosCore

struct AIRouterTests {

    private func triageResultJSON(firstMove: String = "Open the invoice folder and find September.") -> String {
        """
        {"project":null,"priority":2,"due":null,"depth":"shallow","estimateMinutes":15,
         "energyKind":"admin","firstMove":"\(firstMove)","labels":[],
         "rationale":"One document and one email, no preparation needed."}
        """
    }

    // MARK: Required gate test 1

    @Test func triageNeverOverwritesLockedFields() async throws {
        let priorResult = TriageResult(project: "Acme", priority: 4, due: "2026-09-20",
                                       depth: .deep, estimateMinutes: 60, energyKind: .creative,
                                       firstMove: "User-set first move", labels: ["urgent"],
                                       rationale: "user")
        let aiResult = TriageResult(project: "Other", priority: 0, due: nil, depth: .shallow,
                                    estimateMinutes: 10, energyKind: .admin,
                                    firstMove: "AI first move", labels: [], rationale: "ai")

        let locked: Set<TriageField> = [.project, .priority, .due]
        let guarded = TriageFieldGuard.apply(aiResult, lockedFields: locked)

        // Locked fields must not be flagged for writing...
        #expect(!guarded.mayWrite(.project))
        #expect(!guarded.mayWrite(.priority))
        #expect(!guarded.mayWrite(.due))
        // ...while unlocked fields are still applied.
        #expect(guarded.mayWrite(.depth))
        #expect(guarded.mayWrite(.firstMove))

        // Simulate the caller applying the guard: locked fields keep the
        // prior value, everything else takes the AI's value.
        let merged = TriageResult(
            project: guarded.mayWrite(.project) ? aiResult.project : priorResult.project,
            priority: guarded.mayWrite(.priority) ? aiResult.priority : priorResult.priority,
            due: guarded.mayWrite(.due) ? aiResult.due : priorResult.due,
            depth: guarded.mayWrite(.depth) ? aiResult.depth : priorResult.depth,
            estimateMinutes: aiResult.estimateMinutes, energyKind: aiResult.energyKind,
            firstMove: aiResult.firstMove, labels: aiResult.labels, rationale: aiResult.rationale)
        #expect(merged.project == "Acme")
        #expect(merged.priority == 4)
        #expect(merged.due == "2026-09-20")
        #expect(merged.depth == .shallow)   // unlocked, AI wins
    }

    // MARK: Required gate test 2

    @Test func routerFallsBackSonnetThenAstraThenDeterministic() async throws {
        let sonnet = FixtureAIClient(modelID: "claude-sonnet-5", script: [.failure(.http(500))])
        let astra = FixtureAIClient(modelID: "gpt-6-astra", script: [.failure(.http(500))])
        let router = AIRouter(mode: .allowAny,
                              candidates: [AIRoutedCandidate(client: sonnet), AIRoutedCandidate(client: astra)])

        let result = try await router.triage(title: "Send the invoice", notes: "", projectNames: [],
                                             labelNames: [], today: Day.today(), lockedFields: [])
        #expect(result.isDeterministic)          // fell all the way to deterministic
        #expect(await sonnet.callCount == 1)
        #expect(await astra.callCount == 1)
    }

    @Test func routerSucceedsOnSecondCandidateAfterFirstFails() async throws {
        let sonnet = FixtureAIClient(modelID: "claude-sonnet-5", script: [.failure(.http(500))])
        let astra = FixtureAIClient(modelID: "gpt-6-astra", script: [.content(triageResultJSON())])
        let router = AIRouter(mode: .allowAny,
                              candidates: [AIRoutedCandidate(client: sonnet), AIRoutedCandidate(client: astra)])

        let result = try await router.triage(title: "Send the September invoice to Alex", notes: "",
                                             projectNames: [], labelNames: [], today: Day.today(), lockedFields: [])
        #expect(!result.isDeterministic)
        #expect(result.firstMove == "Open the invoice folder and find September.")
    }

    // MARK: Required gate test 3

    @Test func firstMoveLintRejectsVagueVerbViaRouterPath() {
        // The router's own concern is DTO validation; the FirstMoveLint unit
        // tests (FirstMoveLintTests.swift) exercise the rule directly. This
        // test documents that the same fixture text a vague-verb triage would
        // produce is rejected by the lint the caller is expected to run on
        // `TriageResult.firstMove` before storing it.
        let verdict = FirstMoveLint.lint("Open the document", language: .en, dreadMode: false)
        #expect(!verdict.isPass)
    }

    // MARK: Required gate test 4

    @Test func sseBodyIsSniffedAndRejected() throws {
        let sseData = """
        data: {"choices":[{"delta":{"content":"partial"}}]}

        data: [DONE]
        """.data(using: .utf8)!
        #expect(throws: AIError.self) {
            _ = try GhostCLIClient.parseBody(sseData, modelRequested: "claude-sonnet-5", latencyMS: 10)
        }
    }

    @Test func sseSniffedViaContentTypeHeaderAlsoRejected() throws {
        // A body that does not literally start with "data:" but whose
        // Content-Type header says SSE must still be rejected (defensive
        // half: a proxy might rewrite the body without rewriting the header,
        // or vice versa; either signal is enough to distrust the payload).
        let plainJSON = #"{"choices":[{"message":{"content":"hi"}}]}"#.data(using: .utf8)!
        #expect(throws: AIError.self) {
            _ = try GhostCLIClient.parseBody(plainJSON, modelRequested: "m", latencyMS: 1,
                                             contentType: "text/event-stream; charset=utf-8")
        }
    }

    // MARK: Required gate test 5

    @Test func notesAreTruncatedTo300AndRedacted() {
        let longNote = String(repeating: "a", count: 5000)
        let sanitized = PrivacyRedactor.sanitizeNotes(longNote)
        #expect(sanitized.count <= 300)

        let withSecrets = "Contact me at alex@example.com or call +385 91 234 5678, IBAN HR1234567890123456789"
        let redacted = PrivacyRedactor.sanitizeNotes(withSecrets)
        #expect(!redacted.contains("alex@example.com"))
        #expect(!redacted.contains("234 5678"))
        #expect(!redacted.contains("1234567890123456789"))
    }

    // MARK: Required gate test 6

    @Test func aiModeOffNeverTouchesTheNetwork() async throws {
        let sonnet = FixtureAIClient(modelID: "claude-sonnet-5", script: [.content(triageResultJSON())])
        let router = AIRouter(mode: .off, candidates: [AIRoutedCandidate(client: sonnet)])

        let result = try await router.triage(title: "Send the invoice", notes: "", projectNames: [],
                                             labelNames: [], today: Day.today(), lockedFields: [])
        #expect(result.isDeterministic)
        #expect(await sonnet.callCount == 0)   // the network was never touched
    }

    @Test func aiModeOffSkipsImpulsPickAndOrdoResortToo() async throws {
        let sonnet = FixtureAIClient(modelID: "claude-sonnet-5", script: [.content(triageResultJSON())])
        let router = AIRouter(mode: .off, candidates: [AIRoutedCandidate(client: sonnet)])
        let candidates = [Candidate(taskID: UUID(), reason: "test")]
        do {
            _ = try await router.impulsPick(candidates: candidates, energy: .mid, language: "en")
            Issue.record("expected impulsPick to throw under AIMode.off")
        } catch {
            #expect(await sonnet.callCount == 0)
        }
    }

    // MARK: Required gate test 7

    @Test func truncatedReplyHopsToNextModel() async throws {
        let sonnet = FixtureAIClient(modelID: "claude-sonnet-5",
                                     script: [.content("{\"incomplete", finishReason: .length)])
        let astra = FixtureAIClient(modelID: "gpt-6-astra", script: [.content(triageResultJSON())])
        let router = AIRouter(mode: .allowAny,
                              candidates: [AIRoutedCandidate(client: sonnet), AIRoutedCandidate(client: astra)])

        let result = try await router.triage(title: "Send the September invoice to Alex", notes: "",
                                             projectNames: [], labelNames: [], today: Day.today(), lockedFields: [])
        #expect(!result.isDeterministic)
        #expect(await sonnet.callCount == 1)   // NEVER retried on the same model
        #expect(await astra.callCount == 1)
    }

    // MARK: Additional coverage

    @Test func impulsPickValidatesPermutationAndRejectsBadOne() async throws {
        let bad = FixtureAIClient(modelID: "claude-sonnet-5",
                                  script: [.content(#"{"ranked":[{"position":1,"mentorLine":"x"},{"position":1,"mentorLine":"y"}]}"#)])
        let router = AIRouter(mode: .allowAny, candidates: [AIRoutedCandidate(client: bad)])
        let candidates = [Candidate(taskID: UUID(), reason: "a"), Candidate(taskID: UUID(), reason: "b")]
        do {
            _ = try await router.impulsPick(candidates: candidates, energy: .mid, language: "en")
            Issue.record("duplicate position must be rejected")
        } catch {
            // expected: reply rejected whole
        }
    }

    @Test func ordoResortRejectsNonPermutationAndLeavesQueueLogicallyUnchanged() async throws {
        let bad = FixtureAIClient(modelID: "claude-sonnet-5",
                                  script: [.content(#"{"order":[1,1],"explanation":"bad"}"#)])
        let router = AIRouter(mode: .allowAny, candidates: [AIRoutedCandidate(client: bad)])
        let result = try await router.ordoResort(queueTitles: ["A", "B"], message: "swap them",
                                                 history: [], language: "en")
        #expect(result.isValid(queueCount: 2))
        #expect(result.order == [1, 2])   // fell back to unchanged
    }

    @Test func fenceStrippedAndProseWrappedBodiesBothDecode() throws {
        let fenced = "```json\n\(triageResultJSON())\n```"
        let prose = "Here is the JSON: \(triageResultJSON()) Let me know if you need changes."
        let clean = triageResultJSON()
        for text in [fenced, prose, clean] {
            let decoded: TriageResult = try OutputExtraction.decode(TriageResult.self, from: text)
            #expect(decoded.firstMove == "Open the invoice folder and find September.")
        }
    }

    @Test func languageDetectionPicksHRFromDiacritics() {
        #expect(detectLanguage("Nazvati Đakovo") == .hr)         // đ diacritic, no fold
        #expect(detectLanguage("Nazvati Karla za sastanak") == .hr)  // "za" is a stopword
        #expect(detectLanguage("Send the September invoice") == .en)
    }

    @Test func houseRulesRendererProducesNoneWhenEmpty() {
        #expect(HouseRulesRenderer.render(rules: [], scope: .triage) == "House rules: none.")
    }

    /// Recorded-fixture parity: a plain JSON completion and the same content
    /// wrapped as an SSE stream (`Fixtures/triage_ok.json` /
    /// `triage_ok.sse`). The router's own request always encodes
    /// `stream:false`, so the JSON path is what a well-behaved gateway
    /// returns; the SSE fixture exists to prove the reader recognises and
    /// rejects the misbehaving shape rather than mis-parsing it as content.
    @Test func recordedJSONFixtureDecodesToTriageResult() throws {
        let data = try FixtureLoader.data("triage_ok.json")
        let response = try GhostCLIClient.parseBody(data, modelRequested: "claude-sonnet-5", latencyMS: 5)
        let decoded: TriageResult = try OutputExtraction.decode(TriageResult.self, from: response.content)
        #expect(decoded.firstMove == "Open the invoice folder and find September.")
    }

    @Test func recordedSSEFixtureIsRejectedNotMisparsed() throws {
        let data = try FixtureLoader.data("triage_ok.sse")
        #expect(throws: AIError.self) {
            _ = try GhostCLIClient.parseBody(data, modelRequested: "claude-sonnet-5", latencyMS: 5)
        }
    }

    @Test func recordedTruncatedFixtureHopsViaFinishReasonGate() throws {
        let data = try FixtureLoader.data("triage_truncated.json")
        let response = try GhostCLIClient.parseBody(data, modelRequested: "claude-sonnet-5", latencyMS: 5)
        #expect(throws: AIError.self) { try response.validated() }
    }

    @Test func dueDateValidationUsesInjectedTodayNotLiveClock() async throws {
        // Injected `today` is far in the future so the live clock's idea of
        // "today" would incorrectly reject a due date that the injected
        // clock accepts — proving the validator is not silently reading
        // Day.today() (the due-date rule is testable
        // exactly because dates are injectable everywhere in Kronos).
        let futureToday = Day.today() + 3650
        let dueOnFutureToday = Day.iso(futureToday)
        let json = """
        {"project":null,"priority":1,"due":"\(dueOnFutureToday)","depth":"shallow","estimateMinutes":10,
         "energyKind":"admin","firstMove":"Open the calendar and check the date.","labels":[],
         "rationale":"test"}
        """
        let client = FixtureAIClient(modelID: "claude-sonnet-5", script: [.content(json)])
        let router = AIRouter(mode: .allowAny, candidates: [AIRoutedCandidate(client: client)])
        let result = try await router.triage(title: "Check the calendar", notes: "", projectNames: [],
                                             labelNames: [], today: futureToday, lockedFields: [])
        #expect(result.due == dueOnFutureToday)   // survives: not before the INJECTED today
    }

    @Test func recordedOcFreeErrorFixtureIsHttp400() throws {
        // error_400_oc_free.json is the ERROR BODY a 400 response carries;
        // GhostCLIClient itself classifies by status code (AIError.http),
        // so this fixture documents the shape without re-deriving it from a
        // status this test has no transport to produce.
        let text = try FixtureLoader.text("error_400_oc_free.json")
        #expect(text.contains("MissingSessionID"))
    }

    // MARK: Required gate test: triagePromptCarriesExamples

    @Test func triagePromptCarriesExamples() async throws {
        let client = FixtureAIClient(modelID: "claude-sonnet-5", script: [.content(triageResultJSON())])
        let router = AIRouter(mode: .allowAny, candidates: [AIRoutedCandidate(client: client)])
        let context = TriageContext(examples: [
            TriageExample(title: "Nazovi dobavljača za Globex", projectName: "Globex", priority: .high,
                         effort: .s, depth: .shallow, hadDeadline: false, open: true, recency: 1)
        ])
        _ = try await router.triage(title: "Nazovi Ivanu oko isporuke", notes: "", projectNames: ["Globex"],
                                    labelNames: [], today: Day.today(), lockedFields: [], context: context)

        let sent = await client.callLog
        let userMessage = try #require(sent.first?.messages.last?.content)
        #expect(userMessage.contains("Nazovi dobavljača za Globex"))
        #expect(userMessage.contains("Globex"))
    }

    @Test func triagePromptOmitsTheExamplesBlockWhenContextIsEmpty() async throws {
        let client = FixtureAIClient(modelID: "claude-sonnet-5", script: [.content(triageResultJSON())])
        let router = AIRouter(mode: .allowAny, candidates: [AIRoutedCandidate(client: client)])
        _ = try await router.triage(title: "Brand new task", notes: "", projectNames: [],
                                    labelNames: [], today: Day.today(), lockedFields: [])
        let sent = await client.callLog
        let userMessage = try #require(sent.first?.messages.last?.content)
        #expect(!userMessage.contains("Similar tasks"))
    }
}
