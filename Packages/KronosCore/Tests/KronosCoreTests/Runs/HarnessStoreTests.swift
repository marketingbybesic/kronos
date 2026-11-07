#if os(macOS)
import Testing
import Foundation
import SwiftData
@testable import KronosCore

@MainActor
@Suite struct HarnessStoreTests {

    private func store() throws -> HarnessStore {
        HarnessStore(context: ModelContext(try KronosRunsStore.makeContainer(inMemory: true)))
    }

    // MARK: - defaults

    @Test func defaultArgvMatchesEachKnownAgentsPlanTemplate() {
        #expect(HarnessDefaults.defaultArgv(forSlug: "omp") == ["-p", "--no-session", "{prompt}"])
        #expect(HarnessDefaults.defaultArgv(forSlug: "claude") == ["-p", "{prompt}"])
        #expect(HarnessDefaults.defaultArgv(forSlug: "codex") == ["exec", "{prompt}"])
        // positive control: an unknown slug falls back to the minimal "just the prompt" template.
        #expect(HarnessDefaults.defaultArgv(forSlug: "mystery-agent") == ["{prompt}"])
    }

    @Test func modelFlagMatchesEachKnownAgentsCLI() {
        #expect(HarnessDefaults.modelFlag(forSlug: "omp") == "--model")
        #expect(HarnessDefaults.modelFlag(forSlug: "claude") == "--model")
        #expect(HarnessDefaults.modelFlag(forSlug: "codex") == "-m")
        // positive control: an unknown slug falls back to the long flag, not codex's short one.
        #expect(HarnessDefaults.modelFlag(forSlug: "mystery-agent") == "--model")
    }

    @Test func findSearchesTheGivenFoldersInOrderAndSkipsNonExecutables() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("harness-find-" + UUID().uuidString)
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        try fm.createDirectory(at: first, withIntermediateDirectories: true)
        try fm.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let dirs = [first.path, second.path, "/nope"]

        // Not executable: must be skipped even though the name matches, in the first folder.
        let notExecutable = first.appendingPathComponent("claude")
        fm.createFile(atPath: notExecutable.path, contents: Data("x".utf8), attributes: [.posixPermissions: 0o644])
        #expect(HarnessDefaults.find(forSlug: "claude", directories: dirs) == nil, "a non-executable match is skipped")

        let realBinary = second.appendingPathComponent("claude")
        fm.createFile(atPath: realBinary.path, contents: Data("x".utf8), attributes: [.posixPermissions: 0o755])
        #expect(HarnessDefaults.find(forSlug: "claude", directories: dirs) == realBinary.path, "finds the executable in the second folder")
    }

    // MARK: - pin / read

    @Test func pinCreatesThenUpdatesTheSameRowRatherThanDuplicating() throws {
        let s = try store()
        let agentID = UUID()
        let first = s.pin(agentID: agentID, executablePath: "/bin/sh", argvTemplate: ["{prompt}"])
        let second = s.pin(agentID: agentID, executablePath: "/bin/echo", argvTemplate: ["hi", "{prompt}"], maxMinutes: 30)
        #expect(first.id == second.id, "re-pinning updates the one row, never a second")
        #expect(s.harness(agentID: agentID)?.executablePath == "/bin/echo")
        #expect(HarnessArgv.decode(s.harness(agentID: agentID)?.argvTemplate ?? "") == ["hi", "{prompt}"])
        #expect(s.harness(agentID: agentID)?.maxMinutes == 30)
        // positive control: a different agent gets its own row.
        #expect(s.harness(agentID: UUID()) == nil)
    }

    @Test func argvRoundTripsThroughEncodeDecode() {
        let argv = ["-p", "--no-session", "{prompt}"]
        #expect(HarnessArgv.decode(HarnessArgv.encode(argv)) == argv)
        // positive control: garbage decodes to empty, never crashes.
        #expect(HarnessArgv.decode("not json") == [])
        #expect(HarnessArgv.decode("") == [])
    }

    // MARK: - validate

    @Test func validateIsUnpinnedThenOkThenChangedWhenThePathDisappears() throws {
        let s = try store()
        let agentID = UUID()
        #expect(s.validate(agentID: agentID) == .unpinned)
        s.pin(agentID: agentID, executablePath: "/bin/sh", argvTemplate: ["{prompt}"])
        #expect(s.validate(agentID: agentID) == .ok)
        s.pin(agentID: agentID, executablePath: "/no/such/binary-\(UUID().uuidString)", argvTemplate: ["{prompt}"])
        #expect(s.validate(agentID: agentID) == .changed, "the pinned path no longer exists")
    }

    @Test func validateCatchesASymlinkWhoseTargetMovedAfterPinning() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("harness-symlink-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let oldTarget = root.appendingPathComponent("1.0/claude")
        let newTarget = root.appendingPathComponent("1.1/claude")
        try fm.createDirectory(at: oldTarget.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: newTarget.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: oldTarget.path, contents: Data("old".utf8), attributes: [.posixPermissions: 0o755])
        fm.createFile(atPath: newTarget.path, contents: Data("new".utf8), attributes: [.posixPermissions: 0o755])
        let link = root.appendingPathComponent("claude")
        try fm.createSymbolicLink(at: link, withDestinationURL: oldTarget)

        let s = try store()
        let agentID = UUID()
        s.pin(agentID: agentID, executablePath: link.path, argvTemplate: ["{prompt}"])
        #expect(s.validate(agentID: agentID) == .ok, "same symlink target as at pin time")

        // A Homebrew-style upgrade: the top-level path is unchanged, its target moved.
        try fm.removeItem(at: link)
        try fm.createSymbolicLink(at: link, withDestinationURL: newTarget)
        #expect(s.validate(agentID: agentID) == .changed, "the resolved target differs from what was fingerprinted")
    }
}
#endif
