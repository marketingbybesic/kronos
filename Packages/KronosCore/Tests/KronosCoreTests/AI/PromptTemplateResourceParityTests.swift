import Testing
import Foundation
@testable import KronosCore

/// The package has no resource bundle configured (Package.swift is frozen
/// contract surface), so `PromptTemplates`'s Swift constants are what the app
/// actually sends, and `Kronos/Resources/Prompts/*.md` exist only for
/// editing/reference. This suite is the tripwire that keeps them from
/// drifting apart: it locates the repo root from this test file's own path
/// and compares each `.md` file's content, byte for byte modulo one trailing
/// newline, against its Swift constant.
struct PromptTemplateResourceParityTests {

    /// `#filePath` for this test file is
    /// `<repo>/Packages/KronosCore/Tests/KronosCoreTests/AI/<file>.swift`.
    /// Six `deleteLastPathComponent()` calls strip the filename and the five
    /// directories (AI, KronosCoreTests, Tests, KronosCore, Packages) to
    /// land back on `<repo>`.
    private static func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url
    }

    private static func promptFile(_ name: String) -> String? {
        let path = repoRoot().appendingPathComponent("Kronos/Resources/Prompts/\(name)")
        guard let data = FileManager.default.contents(atPath: path.path) else { return nil }
        var s = String(decoding: data, as: UTF8.self)
        if s.hasSuffix("\n") { s.removeLast() }
        return s
    }

    @Test func triageSystemMatchesResourceFile() throws {
        let onDisk = try #require(Self.promptFile("triage.md"))
        #expect(onDisk == PromptTemplates.triageSystem)
    }

    @Test func triageUserTemplateMatchesResourceFile() throws {
        let onDisk = try #require(Self.promptFile("triage_user.md"))
        #expect(onDisk == PromptTemplates.triageUserTemplate)
    }

    @Test func retriageAddendumMatchesResourceFile() throws {
        let onDisk = try #require(Self.promptFile("retriage_with_feedback.md"))
        #expect(onDisk == PromptTemplates.retriageSystemAddendum)
    }

    @Test func impulsPickSystemMatchesResourceFile() throws {
        let onDisk = try #require(Self.promptFile("impuls_pick.md"))
        #expect(onDisk == PromptTemplates.impulsPickSystem)
    }

    @Test func ordoResortSystemMatchesResourceFile() throws {
        let onDisk = try #require(Self.promptFile("ordo_resort.md"))
        #expect(onDisk == PromptTemplates.ordoResortSystem)
    }

    @Test func breakdownSystemMatchesResourceFile() throws {
        let onDisk = try #require(Self.promptFile("breakdown.md"))
        #expect(onDisk == PromptTemplates.breakdownSystem)
    }

    @Test func extractSystemMatchesResourceFile() throws {
        let onDisk = try #require(Self.promptFile("extract.md"))
        #expect(onDisk == PromptTemplates.extractSystem)
    }

    @Test func extractUserTemplateMatchesResourceFile() throws {
        let onDisk = try #require(Self.promptFile("extract_user.md"))
        #expect(onDisk == PromptTemplates.extractUserTemplate)
    }
}
