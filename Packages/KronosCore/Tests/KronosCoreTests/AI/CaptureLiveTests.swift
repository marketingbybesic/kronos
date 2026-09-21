// Opt-in live tests against the real GhostCLI gateway, mirroring
// LiveProbeTests.swift's pattern: skipped unless KRONOS_LIVE_AI=1, calling
// GhostCLIClient DIRECTLY (no router, no fallback) so a down gateway or
// expired key fails the test instead of silently passing through the
// router's deterministic fallback. Prints only non-secret diagnostics.
//
// Run with:
//   KRONOS_LIVE_AI=1 swift test --package-path Packages/KronosCore \
//     --scratch-path build/spm-9a --filter CaptureLiveTests
//
// Fixture text below uses neutral names (Alex, Acme, Globex) since
// this data policy is `.unknown` and does leave the
// machine on a live run.

import Testing
import Foundation
@testable import KronosCore

struct CaptureLiveTests {

    @Test func liveExtractReturnsModelTasks() async throws {
        guard ProcessInfo.processInfo.environment["KRONOS_LIVE_AI"] == "1" else {
            return   // skipped: not opted in
        }
        let notes = """
        - nazvati Alexa oko isporuke za Acme
        - poslati račun Globexu do petka
        - kupiti kavu za ured
        - rezervirati salu za sastanak
        - provjeriti stanje zaliha
        - napisati tjedni izvještaj
        - odgovoriti na mail od dobavljača
        - platiti račun za struju
        """
        let today = Day.today()
        let language = detectLanguage(notes)
        let system = TemplateFill.fill(PromptTemplates.extractSystem, [
            "HOUSE_RULES": "House rules: none.",
            "LANG_NAME": language.name, "LANG": language.rawValue
        ])
        let user = TemplateFill.fill(PromptTemplates.extractUserTemplate, [
            "TODAY_ISO": Day.iso(today),
            "PROJECT_NAMES": "Acme, Globex",
            "LABEL_NAMES": "",
            "EXISTING_TITLES": "",
            "NOTES_6000": PrivacyRedactor.sanitizeCapture(notes)
        ])
        let request = AIRequest(model: "claude-sonnet-5",
                                messages: [.system(system), .user(user)], kind: .extract)

        let client = GhostCLIClient(modelID: "claude-sonnet-5")
        let response = try await client.send(request)   // THROWS on failure — no try?
        try response.validated()

        // The extract reply is the app's own outline syntax, not JSON — see
        // ExtractOutlineValidator.validateExtractOutline (AIRouter+Capture.swift).
        let outline = ExtractOutlineValidator.extractOutlineBlock(response.content)
        let tasks = try ExtractOutlineValidator.validateExtractOutline(outline, sourceText: notes,
                                                         projectNames: ["Acme", "Globex"], today: today)

        #expect(!tasks.isEmpty)
        #expect(tasks.allSatisfy { $0.priority != .none && $0.effort != .none })
        print("live extract: model=\(response.modelRequested) latencyMS=\(response.latencyMS) "
            + "titles=\(tasks.map(\.title))")
    }

    @Test func liveBreakdownReturnsSteps() async throws {
        guard ProcessInfo.processInfo.environment["KRONOS_LIVE_AI"] == "1" else {
            return   // skipped: not opted in
        }
        let title = "Send the September invoice to Alex"
        let language = detectLanguage(title)
        let system = TemplateFill.fill(PromptTemplates.breakdownSystem, [
            "HOUSE_RULES": "House rules: none.",
            "LANG_NAME": language.name, "LANG": language.rawValue
        ])
        let user = TemplateFill.fill(PromptTemplates.breakdownUserTemplate, [
            "TITLE": title, "NOTES_300": "", "EST": "20"
        ])
        let request = AIRequest(model: "claude-sonnet-5",
                                messages: [.system(system), .user(user)], kind: .breakdown)

        let client = GhostCLIClient(modelID: "claude-sonnet-5")
        let response = try await client.send(request)   // THROWS on failure — no try?
        try response.validated()

        let result = try AIRouter.validateBreakdown(
            try #require(response.content.data(using: .utf8)), existingSubtasks: [])

        #expect((3...7).contains(result.subtasks.count))
        print("live breakdown: model=\(response.modelRequested) latencyMS=\(response.latencyMS) "
            + "steps=\(result.subtasks)")
    }
}
