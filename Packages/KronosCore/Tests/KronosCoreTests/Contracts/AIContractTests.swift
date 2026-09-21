import Testing
import Foundation
@testable import KronosCore

/// The two rules from BUILD-PROMPT §3 that are build failures when broken.
struct AIContractTests {

    // MARK: - stream (BUILD-PROMPT §3.5)

    @Test func streamIsEncodedAsLiteralFalse() throws {
        let req = AIRequest(model: "claude-sonnet-5",
                            messages: [.system("s"), .user("u")],
                            kind: .triage)
        let body = try req.encodedBody()
        let json = try #require(String(data: body, encoding: .utf8))

        // The literal the gateway needs. Omitting the key makes it answer
        // text/event-stream, which crashes JSONDecoder.
        #expect(json.contains("\"stream\":false"))
        #expect(!json.contains("\"stream\":null"))
    }

    @Test func streamIsPresentForEveryPromptKind() throws {
        for kind in PromptKind.allCases {
            let req = AIRequest(model: "m", messages: [.user("u")], kind: kind)
            let json = try #require(String(data: try req.encodedBody(), encoding: .utf8))
            #expect(json.contains("\"stream\":false"), "missing for \(kind)")
        }
    }

    // MARK: - reasoning switch (measured 2026-09-21: OpenRouter reasoning models blow the budget)

    @Test func reasoningIsAbsentUnlessSet() throws {
        let req = AIRequest(model: "m", messages: [.user("u")], kind: .triage)
        let json = try #require(String(data: try req.encodedBody(), encoding: .utf8))
        #expect(!json.contains("reasoning"))
    }

    @Test func reasoningOffEncodesTheOpenRouterShape() throws {
        var req = AIRequest(model: "m", messages: [.user("u")], kind: .triage)
        req.reasoning = AIRequest.ReasoningControl(enabled: false)
        let json = try #require(String(data: try req.encodedBody(), encoding: .utf8))
        #expect(json.contains("\"reasoning\":{\"enabled\":false}"))
        #expect(json.contains("\"stream\":false"))
    }

    @Test func triageBudgetOutlivesMeasuredModelSpikes() {
        #expect(AIBudget.seconds(for: .triage) >= 45)
    }

    @Test func maxTokensUsesTheSnakeCaseWireKeyAndNeverFourHundred() throws {
        let triage = AIRequest(model: "m", messages: [.user("u")], kind: .triage)
        let resort = AIRequest(model: "m", messages: [.user("u")], kind: .ordoResort)

        let json = try #require(String(data: try triage.encodedBody(), encoding: .utf8))
        #expect(json.contains("\"max_tokens\":2500"))
        #expect(!json.contains("\"maxTokens\""))

        #expect(triage.maxTokens == 2500)
        #expect(resort.maxTokens == 4000)
    }

    @Test func impulsBudgetIsFourSecondsHard() {
        #expect(AIBudget.seconds(for: .impulsPick) == 4)
        #expect(AIBudget.seconds(for: .triage) == 45) // measured model spikes require the higher budget
        #expect(AIBudget.seconds(for: .ordoResort) == 25)
        #expect(AIRequest(model: "m", messages: [], kind: .impulsPick).budgetSeconds == 4)
    }

    // MARK: - truncation (ai-2)

    @Test func lengthFinishReasonSurfacesAsTruncated() throws {
        let response = AIResponse(content: "{\"pri",
                                  finishReason: .length,
                                  modelRequested: "claude-sonnet-5",
                                  reasoningTokens: 269)

        #expect(throws: AIError.truncated(reasoningTokens: 269)) {
            try response.validated()
        }
    }

    @Test func stopFinishReasonPassesValidation() throws {
        let response = AIResponse(content: "{}",
                                  finishReason: .stop,
                                  modelRequested: "claude-sonnet-5")
        let ok = try response.validated()
        #expect(ok.content == "{}")
    }

    @Test func finishReasonMapsBothProviderSpellings() {
        #expect(FinishReason(wire: "length") == .length)
        #expect(FinishReason(wire: "max_tokens") == .length)   // Anthropic
        #expect(FinishReason(wire: "stop") == .stop)
        #expect(FinishReason(wire: "end_turn") == .stop)       // Anthropic
        #expect(FinishReason(wire: "something_new") == .other)
        #expect(FinishReason(wire: nil) == .other)
    }

    // MARK: - routing classification

    @Test func truncatedAndBadJSONHopButAuthFailuresDoNot() {
        #expect(AIError.truncated(reasoningTokens: nil).shouldHop)
        #expect(AIError.badJSON(prefix: "<html>").shouldHop)
        #expect(AIError.timeout(budgetSeconds: 4).shouldHop)
        #expect(AIError.http(500).shouldHop)
        #expect(AIError.http(429).shouldHop)
        #expect(!AIError.http(401).shouldHop)
        #expect(!AIError.http(403).shouldHop)
        #expect(!AIError.noUsableProvider.shouldHop)
    }

    @Test func dataPolicyDefaultsToUnknownForTheShippedGateway() {
        // SPEC §12.6: the default gateway's data policy is explicitly `unknown`.
        #expect(DataPolicy(rawValue: "unknown") == .unknown)
        // `.onDevice` covers the on-device Apple Intelligence client.
        #expect(DataPolicy.allCases.count == 4)
        #expect(AIMode.allCases.contains(.off))
    }
}
