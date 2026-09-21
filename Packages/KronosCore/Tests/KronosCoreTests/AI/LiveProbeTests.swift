import Testing
import Foundation
@testable import KronosCore

/// Opt-in live tests against the real GhostCLI gateway with the real
/// Keychain key. Skipped unless `KRONOS_LIVE_AI=1` is set, so `swift test`
/// never makes a network call by default (a fixture
/// pass + live fail is reported as AI provider down, not a build failure).
///
/// Run with:
///   KRONOS_LIVE_AI=1 swift test --package-path Packages/KronosCore \
///     --scratch-path build/spm-3a --filter LiveProbeTests
///
/// Requires the Keychain entry `ghostcli_api` to already hold a valid
/// bearer token. The key is read by
/// `KeychainKeyProvider` and is never printed, logged, or included in any
/// assertion or print statement below. Test fixtures below use neutral
/// names ("Alex", "Acme", "Globex") rather than any real client
/// names, since this data policy is `.unknown` and does leave
/// the machine on a live run.
struct LiveProbeTests {

    /// Router-mediated: proves the app-level contract (deterministic
    /// fallback, field validation) still holds against a live reply. This
    /// test CANNOT fail on a down gateway — the router's whole point is to
    /// fall back silently — so it does not by itself prove the model
    /// answered. `liveClientReturnsModelReply` and `liveRouterDidNotFallBack`
    /// below are what actually exercise the network path.
    @Test func liveTriageReturnsValidJSON() async throws {
        guard ProcessInfo.processInfo.environment["KRONOS_LIVE_AI"] == "1" else {
            return   // skipped: not opted in
        }
        let client = GhostCLIClient(modelID: "claude-sonnet-5")
        let router = AIRouter(mode: .allowAny, candidates: [AIRoutedCandidate(client: client)])

        let result = try await router.triage(
            title: "Send the September invoice to Alex",
            notes: "", projectNames: ["Acme", "Globex"], labelNames: [],
            today: Day.today(), lockedFields: [])

        #expect(!result.firstMove.isEmpty)
        #expect(result.firstMove.count <= 100)
        #expect((0...4).contains(result.priority))
    }

    /// Calls `GhostCLIClient` DIRECTLY — no router, no fallback, errors
    /// THROW. This is the test that actually proves the gateway answered:
    /// a down gateway or expired key fails this test instead of silently
    /// passing. Prints only non-secret diagnostics (model id, latency,
    /// finish reason, decoded firstMove) — never the key, never headers.
    @Test func liveClientReturnsModelReply() async throws {
        guard ProcessInfo.processInfo.environment["KRONOS_LIVE_AI"] == "1" else {
            return   // skipped: not opted in
        }
        let language = detectLanguage("Send the September invoice to Alex")
        let system = TemplateFill.fill(PromptTemplates.triageSystem, [
            "HOUSE_RULES": "House rules: none.",
            "LANG_NAME": language.name, "LANG": language.rawValue
        ])
        let user = TemplateFill.fill(PromptTemplates.triageUserTemplate, [
            "TODAY_ISO": Day.iso(Day.today()), "WEEKDAY": "Saturday",
            "PROJECT_NAMES": "Acme, Globex", "LABEL_NAMES": "",
            "TITLE": "Send the September invoice to Alex", "NOTES_300": ""
        ])
        let request = AIRequest(model: "claude-sonnet-5",
                                messages: [.system(system), .user(user)], kind: .triage)

        let client = GhostCLIClient(modelID: "claude-sonnet-5")
        let response = try await client.send(request)   // THROWS on failure — no try?
        try response.validated()                        // finish_reason gate

        #expect(!response.modelRequested.isEmpty)
        #expect(!response.content.isEmpty)
        #expect(response.latencyMS > 0)

        let decoded: TriageResult = try OutputExtraction.decode(TriageResult.self, from: response.content)
        let validated = try AIRouter.validateTriage(
            try #require(response.content.data(using: .utf8)),
            projectNames: ["Acme", "Globex"], labelNames: [], today: Day.today())
        #expect(!validated.firstMove.isEmpty)

        print("live probe: model=\(response.modelRequested) latencyMS=\(response.latencyMS) "
            + "finishReason=\(response.finishReason) firstMove=\(decoded.firstMove)")
    }

    /// Routes the SAME input through `AIRouter`, configured with the actual
    /// production fallback chain (`claude-sonnet-5 -> gpt-6-astra`),
    /// and asserts the result is NOT the deterministic
    /// fallback — i.e. the router actually reached a model rather than
    /// silently degrading. Uses `TriageResult.isDeterministic`
    /// (`version == 0`), the existing fallback marker the UI already needs
    /// to decide whether to show the AI sparkle.
    ///
    /// Both candidates are configured deliberately, not one: a live model
    /// occasionally omits a required field on a single call (observed
    /// 2026-09-19 — `claude-sonnet-5` returned valid, complete JSON with
    /// `finish_reason: "stop"` but no `priority` key, which the frozen
    /// `TriageResult` decoder correctly treats as `badJSON` and hops on).
    /// With only one candidate configured that single miss has nowhere to
    /// hop to and would show up here as an indistinguishable false
    /// "fell back" — exactly the ambiguity this test exists to remove, so
    /// the chain must match what the app actually runs.
    @Test func liveRouterDidNotFallBack() async throws {
        guard ProcessInfo.processInfo.environment["KRONOS_LIVE_AI"] == "1" else {
            return   // skipped: not opted in
        }
        let sonnet = GhostCLIClient(modelID: "claude-sonnet-5")
        let astra = GhostCLIClient(modelID: "gpt-6-astra")
        let router = AIRouter(mode: .allowAny,
                              candidates: [AIRoutedCandidate(client: sonnet), AIRoutedCandidate(client: astra)])

        let result = try await router.triage(
            title: "Send the September invoice to Alex",
            notes: "", projectNames: ["Acme", "Globex"], labelNames: [],
            today: Day.today(), lockedFields: [])

        #expect(!result.isDeterministic)
        print("live probe: routed firstMove=\(result.firstMove)")
    }
}
