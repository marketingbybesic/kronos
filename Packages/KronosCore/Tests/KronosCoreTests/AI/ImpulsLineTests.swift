import Testing
import Foundation
@testable import KronosCore

private let rankingReply = """
{"ranked":[{"position":1,"mentorLine":"Short, fits before the next meeting."}]}
"""

/// The Impuls mentor line is asked of a fast model only.
struct ImpulsFastModelTests {

    @Test func modelIdTable() {
        let table: [(String, Bool)] = [
            ("claude-sonnet-5", false),
            ("claude-opus-5", false),
            ("claude-fable-5.1", false),
            ("gpt-6-astra", true),
            ("GPT-6-ASTRA", true),
            ("qwen/qwen3.8-27b:free", true),
            ("nvidia/nemotron-3-ultra-550b-a55b:free", false),
            ("apple-on-device", true),
            ("", false),
        ]
        for (id, expected) in table {
            #expect(FastModel.isFast(modelID: id) == expected, "\(id)")
        }
    }

    private func router(model: String, mode: AIMode = .allowAny) -> (AIRouter, FixtureAIClient) {
        let client = FixtureAIClient(modelID: model, script: [.content(rankingReply)])
        return (AIRouter(mode: mode, candidates: [AIRoutedCandidate(client: client)]), client)
    }

    private let candidate = Candidate(taskID: UUID(), reason: "Due today")

    @Test func theDefaultModelMakesNoImpulsCall() async throws {
        let (router, client) = router(model: "claude-sonnet-5")
        #expect(!router.supportsImpulsLine)
        await #expect(throws: AIError.noUsableProvider) {
            _ = try await router.impulsPick(candidates: [candidate], energy: .mid, language: "en")
        }
        #expect(await client.callCount == 0)
    }

    @Test func aFastModelIsAskedExactlyOnce() async throws {
        let (router, client) = router(model: "gpt-6-astra")
        #expect(router.supportsImpulsLine)
        let ranking = try await router.impulsPick(candidates: [candidate], energy: .mid, language: "en")
        #expect(ranking.ranked.first?.position == 1)
        #expect(await client.callCount == 1)
    }

    @Test func aSlowFirstModelIsSkippedAndTheFastOneAnswers() async throws {
        let slow = FixtureAIClient(modelID: "claude-sonnet-5", script: [.content(rankingReply)])
        let fast = FixtureAIClient(modelID: "gpt-6-astra", script: [.content(rankingReply)])
        let router = AIRouter(mode: .allowAny, candidates: [AIRoutedCandidate(client: slow), AIRoutedCandidate(client: fast)])
        _ = try await router.impulsPick(candidates: [candidate], energy: .mid, language: "en")
        #expect(await slow.callCount == 0)
        #expect(await fast.callCount == 1)
    }

    @Test func withAIOffNoModelIsAsked() async throws {
        let (router, client) = router(model: "gpt-6-astra", mode: .off)
        #expect(!router.supportsImpulsLine)
        await #expect(throws: AIError.noUsableProvider) {
            _ = try await router.impulsPick(candidates: [candidate], energy: .mid, language: "en")
        }
        #expect(await client.callCount == 0)
    }

    @Test func aRouterThatKnowsNothingAboutItsModelsStaysAllowed() {
        struct Plain: AIRouting {
            func triage(title: String, notes: String, projectNames: [String], labelNames: [String], today: Int,
                        lockedFields: Set<String>, context: TriageContext) async throws -> TriageResult { throw AIError.noUsableProvider }
            func retriage(title: String, notes: String, previous: TriageResult, feedback: String,
                          projectNames: [String], labelNames: [String], today: Int) async throws -> TriageResult { previous }
            func impulsPick(candidates: [Candidate], energy: KEnergyLevel, language: String) async throws -> ImpulsRanking { ImpulsRanking(ranked: []) }
            func ordoResort(queueTitles: [String], message: String, history: [String], language: String) async throws -> OrdoResort { .unchanged(queueCount: 0) }
            func extractTasks(from text: String, projectNames: [String], existingOpenTitles: [String], today: Int) async -> ExtractResult {
                ExtractResult(tasks: [], droppedLineCount: 0, isDeterministic: true, reason: .aiOff)
            }
            func breakdown(title: String, notes: String, existingSubtasks: [String]) async -> BreakdownResult {
                BreakdownResult(subtasks: [], firstMove: "", isDeterministic: true)
            }
        }
        #expect(Plain().supportsImpulsLine)
    }
}

/// One ask per card, a line the prompt and the lint agree on.
struct ImpulsRefinementTests {

    @Test func theGateAdmitsOneAskPerTaskUntilReset() {
        var gate = RefinementGate()
        let a = UUID(), b = UUID()
        let asks = [gate.shouldRequest(for: a), gate.shouldRequest(for: a), gate.shouldRequest(for: a),
                    gate.shouldRequest(for: b), gate.shouldRequest(for: a)]
        #expect(asks == [true, false, false, true, true])
        gate.reset()
        let afterReset = gate.shouldRequest(for: a)
        #expect(afterReset)
    }

    @Test func promptAndLintAgreeOnNinetyCharacters() {
        #expect(MentorLineLimits.maxCharacters == 90)
        #expect(PromptTemplates.impulsPickSystem.contains("maximum 90 characters"))
        #expect(PromptTemplates.impulsPickSystem.contains("1-90 characters"))
        #expect(!PromptTemplates.impulsPickSystem.contains("140"))
    }

    @Test func lineLengthBoundary() {
        let ninety = String(repeating: "a", count: 90)
        let ninetyOne = String(repeating: "a", count: 91)
        #expect(MentorLineCheck.pass(ninety, unlessIdenticalTo: "generic"))
        #expect(!MentorLineCheck.pass(ninetyOne, unlessIdenticalTo: "generic"))
    }

    @Test func lintTableEnglishAndCroatian() {
        let table: [(String, Bool)] = [
            ("One ten-minute call, nothing after it.", true),
            ("Jedan kratak poziv, ništa poslije.", true),
            ("You've got this, just start", false),
            ("Moraš to napraviti danas", false),
            ("Hajde, počni s prvim korakom", false),
            ("Već dugo čeka na tebe", false),
            ("Short line!", false),
            ("Is it due today?", false),
            ("First sentence. Second sentence. Third.", false),
        ]
        for (line, expected) in table {
            #expect(MentorLineCheck.pass(line, unlessIdenticalTo: "generic") == expected, "\(line)")
        }
        #expect(!MentorLineCheck.pass("generic", unlessIdenticalTo: "generic"))
    }
}
