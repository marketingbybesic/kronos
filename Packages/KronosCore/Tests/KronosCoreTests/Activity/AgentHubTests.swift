import Testing
import Foundation
import SwiftData
@testable import KronosCore

@MainActor
@Suite struct AgentHubTests {

    private func tempFiles() -> AgentTokenFiles {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kronos-agent-tokens-\(UUID().uuidString)")
        return AgentTokenFiles(secretsDirectory: dir)
    }

    private func hub(_ files: AgentTokenFiles? = nil, now: @escaping () -> Date = { Date() }) throws -> AgentHub {
        AgentHub(context: ModelContext(try KronosLocalStore.makeContainer(inMemory: true)), tokenFiles: files, now: now)
    }

    // MARK: scopes

    @Test func scopesRoundTripThroughTheCsvInDeclarationOrder() {
        let s = AgentScopes([.comment, .read, .writeOwn])
        #expect(s.csv == "read,write.own,comment")
        #expect(AgentScopes(csv: s.csv) == s)
        #expect(AgentScopes(csv: "read, propose ,nonsense").set == [.read, .propose])
        #expect(AgentScopes(csv: "").set.isEmpty)
    }

    @Test func standardAndLegacyScopesAreAsWritten() {
        #expect(AgentScopes.standard.csv == "read,propose,write.own,comment")
        #expect(AgentScopes.legacy.csv == "read,propose")
        #expect(!AgentScopes.standard.has(.writeTrusted), "write.trusted is opt-in")
    }

    // MARK: tokens

    @Test func hashIsTheKnownSHA256OfTheToken() {
        // shasum -a 256 of "tok-123", computed outside the code under test.
        #expect(AgentTokenFiles.hash("tok-123") == "c8963414bf6c4c869eeac5f8a057c3dc574d422f1b108397b66f67bab3d2f981")
    }

    @Test func generatedTokensAreLongDistinctAndUrlSafe() throws {
        let a = try #require(AgentTokenFiles.generateToken())
        let b = try #require(AgentTokenFiles.generateToken())
        #expect(a != b && a.count >= 43)
        #expect(a.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }

    @Test func slugsAreCleanedAndValidated() {
        #expect(AgentTokenFiles.slug(from: "Claude Code") == "claude-code")
        #expect(AgentTokenFiles.slug(from: "  Relay!! ") == "relay")
        #expect(AgentTokenFiles.slug(from: "!!!") == nil)
        for bad in ["", "-x", "A", "a b", "../x", "a/b", String(repeating: "a", count: 33)] { #expect(!AgentTokenFiles.isValidSlug(bad), "\(bad)") }
        #expect(AgentTokenFiles.isValidSlug("claude-code"))
    }

    @Test func tokenFilesAreUserOnlyAndNeverPathTraversal() throws {
        let files = tempFiles()
        try files.write("secret-token", slug: "codex")
        let attrs = try FileManager.default.attributesOfItem(atPath: files.directory.appendingPathComponent("codex.token").path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
        let dir = try FileManager.default.attributesOfItem(atPath: files.directory.path)
        #expect((dir[.posixPermissions] as? Int) == 0o700)
        #expect(throws: (any Error).self) { try files.write("x", slug: "../evil") }
        #expect(files.read("../evil") == nil)
        #expect(files.allSlugs() == ["codex"])
    }

    // MARK: authentication

    @Test func anAgentTokenResolvesToItsAgentAndScopes() throws {
        let files = tempFiles()
        let h = try hub(files)
        let made = try #require(h.addAgent(displayName: "Claude Code", scopes: AgentScopes([.read, .comment])))
        #expect(made.agent.slug == "claude-code")
        guard case .agent(let id) = h.authenticate(bearer: made.token, legacyToken: "shared", client: "whatever") else {
            Issue.record("token not accepted"); return
        }
        #expect(id.slug == "claude-code" && id.agentID == made.agent.id && !id.isLegacy)
        #expect(id.scopes.set == [.read, .comment])
        #expect(files.read("claude-code") == made.token)
    }

    @Test func theRowKeepsOnlyTheHashNeverTheToken() throws {
        let h = try hub(tempFiles())
        let made = try #require(h.addAgent(displayName: "Codex"))
        #expect(made.agent.tokenHash == AgentTokenFiles.hash(made.token))
        #expect(!made.agent.tokenHash.contains(made.token))
        for row in h.agents() { #expect(!(row.scopesRaw + row.tokenHash + row.displayName).contains(made.token)) }
    }

    @Test func wrongEmptyOrMissingBearerIsDenied() throws {
        let h = try hub(tempFiles())
        _ = h.addAgent(displayName: "Codex")
        #expect(h.authenticate(bearer: "nope", legacyToken: "shared", client: nil) == .denied)
        #expect(h.authenticate(bearer: "", legacyToken: "shared", client: nil) == .denied)
        #expect(h.authenticate(bearer: nil, legacyToken: "shared", client: nil) == .denied)
        #expect(h.authenticate(bearer: "shared", legacyToken: nil, client: nil) == .denied)
        #expect(h.authenticate(bearer: "shared", legacyToken: "", client: nil) == .denied)
    }

    @Test func aDisabledAgentIsDeniedAndAnEnabledOneIsBack() throws {
        let h = try hub(tempFiles())
        let made = try #require(h.addAgent(displayName: "Codex"))
        h.setEnabled(false, slug: "codex")
        #expect(h.authenticate(bearer: made.token, legacyToken: nil, client: nil) == .denied)
        h.setEnabled(true, slug: "codex")
        #expect(h.authenticate(bearer: made.token, legacyToken: nil, client: nil) != .denied)
    }

    @Test func rotatingInvalidatesTheOldTokenAtOnce() throws {
        let h = try hub(tempFiles())
        let made = try #require(h.addAgent(displayName: "Codex"))
        let fresh = try #require(h.rotateToken(slug: "codex"))
        #expect(fresh != made.token)
        #expect(h.authenticate(bearer: made.token, legacyToken: nil, client: nil) == .denied)
        #expect(h.authenticate(bearer: fresh, legacyToken: nil, client: nil) != .denied)
    }

    @Test func aTokenFileWrittenOutsideTheAppRegistersItsAgentOnFirstUse() throws {
        let files = tempFiles()
        let h = try hub(files)
        try files.write("written-by-connect-all", slug: "relay")
        #expect(h.agent(slug: "relay") == nil)
        guard case .agent(let id) = h.authenticate(bearer: "written-by-connect-all", legacyToken: nil, client: nil) else {
            Issue.record("file token not accepted"); return
        }
        #expect(id.slug == "relay" && id.scopes == .standard)
        #expect(h.agent(slug: "relay")?.displayName == "Relay")
        // A file that was rotated by hand refreshes the stored hash.
        try files.write("rotated-by-hand", slug: "relay")
        #expect(h.authenticate(bearer: "rotated-by-hand", legacyToken: nil, client: nil) != .denied)
        #expect(h.authenticate(bearer: "written-by-connect-all", legacyToken: nil, client: nil) == .denied)
    }

    @Test func theLegacyTokenIsAnUnnamedAgentWithReadAndPropose() throws {
        let h = try hub()
        guard case .agent(let id) = h.authenticate(bearer: "shared", legacyToken: "shared", client: nil) else {
            Issue.record("legacy token not accepted"); return
        }
        #expect(id.isLegacy && id.slug == "unnamed" && id.scopes == .legacy)
        #expect(h.agent(slug: "unnamed")?.displayName == "Unnamed agent")
    }

    @Test func aLegacyClientIsNamedAfterItsClientHeaderButNeverBorrowsARealAgentsRights() throws {
        let h = try hub(tempFiles())
        let real = try #require(h.addAgent(displayName: "Codex"))
        guard case .agent(let named) = h.authenticate(bearer: "shared", legacyToken: "shared", client: "Cursor") else { Issue.record("denied"); return }
        #expect(named.slug == "cursor" && named.scopes == .legacy)
        guard case .agent(let clash) = h.authenticate(bearer: "shared", legacyToken: "shared", client: "codex") else { Issue.record("denied"); return }
        #expect(clash.slug == "unnamed" && clash.agentID != real.agent.id && clash.scopes == .legacy)
    }

    @Test func lastSeenIsRecordedAndThrottled() throws {
        var t = Date(timeIntervalSince1970: 1_000)
        let h = try hub(tempFiles(), now: { t })
        let made = try #require(h.addAgent(displayName: "Codex"))
        #expect(made.agent.lastSeenAt == nil)
        _ = h.authenticate(bearer: made.token, legacyToken: nil, client: nil)
        #expect(made.agent.lastSeenAt == t)
        t = t.addingTimeInterval(10)
        _ = h.authenticate(bearer: made.token, legacyToken: nil, client: nil)
        #expect(made.agent.lastSeenAt == Date(timeIntervalSince1970: 1_000), "within 30 s nothing is rewritten")
        t = t.addingTimeInterval(60)
        _ = h.authenticate(bearer: made.token, legacyToken: nil, client: nil)
        #expect(made.agent.lastSeenAt == t)
    }

    @Test func removingAnAgentDeletesItsRowAndTokenFile() throws {
        let files = tempFiles()
        let h = try hub(files)
        let made = try #require(h.addAgent(displayName: "Codex"))
        h.remove(slug: "codex")
        #expect(h.agent(slug: "codex") == nil && files.read("codex") == nil)
        #expect(h.authenticate(bearer: made.token, legacyToken: nil, client: nil) == .denied)
    }

    @Test func aDuplicateNameIsNotAddedTwice() throws {
        let h = try hub(tempFiles())
        _ = try #require(h.addAgent(displayName: "Codex"))
        #expect(h.addAgent(displayName: "codex") == nil)
    }
}
