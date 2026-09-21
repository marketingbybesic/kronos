import Testing
import Foundation
@testable import KronosCore

/// Opt-in live test against the REAL on-device Apple Intelligence model.
/// Skipped unless `KRONOS_LIVE_APPLE=1` is set, so `swift test` never
/// prompts for Apple Intelligence consent or burns model latency by default.
///
/// Run with:
///   KRONOS_LIVE_APPLE=1 swift test --package-path Packages/KronosCore \
///     --scratch-path build/spm-10a --filter LiveAppleIntelligenceTests
///
/// Calls `AppleIntelligenceClient` DIRECTLY — no `AIRouter`, no fallback —
/// exactly like `LiveProbeTests.liveClientReturnsModelReply`, and for the
/// same reason: a router's whole point is to fall back silently, which would
/// let a broken on-device path hide behind "the deterministic answer looked
/// fine". This test either proves the model answered, or honestly records
/// why it could not, and it treats those as two different outcomes:
///   - available AND the reply validates          -> PASS
///   - available but the reply does NOT validate   -> FAIL (this is the bug
///     this test exists to catch; "the model is there but broken" is not an
///     acceptable silent skip)
///   - unavailable for any reason                  -> PASS, printing
///     "UNAVAILABLE: <reason>" so a human reads the actual cause on this Mac
///     without the run being reported as a failure of a feature the Mac
///     cannot exercise at all.
struct LiveAppleIntelligenceTests {

    @Test func liveAppleIntelligenceTriage() async throws {
        guard ProcessInfo.processInfo.environment["KRONOS_LIVE_APPLE"] == "1" else {
            return   // skipped: not opted in
        }

        let availability = AppleIntelligence.availability
        guard availability == .available else {
            print("UNAVAILABLE: \(availability.statusLine)")
            return   // PASS: honestly recorded, never faked as a working model
        }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let client = AppleIntelligenceClient()
            let language = detectLanguage("Send the September invoice to Alex")
            let system = TemplateFill.fill(PromptTemplates.triageSystem, [
                "HOUSE_RULES": "House rules: none.",
                "LANG_NAME": language.name, "LANG": language.rawValue
            ])
            let user = TemplateFill.fill(PromptTemplates.triageUserTemplate, [
                "TODAY_ISO": Day.iso(Day.today()), "WEEKDAY": "Saturday",
                "PROJECT_NAMES": "Acme, Globex", "LABEL_NAMES": "",
                "EXAMPLES": "",
                "TITLE": "Send the September invoice to Alex", "NOTES_300": ""
            ])
            let request = AIRequest(model: client.modelID,
                                    messages: [.system(system), .user(user)], kind: .triage)

            // THROWS on failure — no try?. `.available` was just confirmed,
            // so any throw here (transport, guardrail, bad reply) is a real
            // failure of a model that reported itself ready, not something
            // to swallow.
            let response = try await client.send(request)
            try response.validated()

            #expect(!response.content.isEmpty)
            let sliced = OutputExtraction.braceSlice(OutputExtraction.stripFences(response.content))
            guard let data = sliced.data(using: .utf8) else {
                Issue.record("Apple Intelligence reply was not valid UTF-8 JSON: \(response.content.prefix(200))")
                return
            }
            let validated = try AIRouter.validateTriage(data, projectNames: ["Acme", "Globex"],
                                                        labelNames: [], today: Day.today())
            #expect(!validated.firstMove.isEmpty)
            #expect(validated.firstMove.count <= 100)

            print("live Apple Intelligence probe: firstMove=\(validated.firstMove) "
                + "priority=\(validated.priority) latencyMS=\(response.latencyMS)")
        }
        #endif
    }
}
