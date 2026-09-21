// Every test here uses `FakeSecretStore`/`FakeLegacySecretReader` (in-memory, never a
// Security framework call): a test that reaches the real Keychain makes macOS prompt to
// unlock it for whatever binary is running the test, which freezes an automated run. One
// test below asserts, statically, that the default real store is never constructed on the
// test path at all.
import Testing
import Foundation
@testable import KronosCore

@Suite("Secret")
struct SecretStoringTests {

    @Test func writeThenReadRoundTrips() throws {
        let store = FakeSecretStore()
        try store.write("token-value", name: "example")
        #expect(store.read("example") == "token-value")
    }

    @Test func readOfNameNeverWrittenIsNil() {
        let store = FakeSecretStore()
        #expect(store.read("never-written") == nil)
    }

    @Test func deleteClearsTheValueAndTheHasFlag() throws {
        let store = FakeSecretStore()
        try store.write("v", name: "example")
        #expect(store.hasValue("example"))
        store.delete("example")
        #expect(store.read("example") == nil)
        #expect(!store.hasValue("example"))
    }

    @Test func hasValueNeverCountsAsARead() throws {
        let store = FakeSecretStore()
        try store.write("v", name: "example")
        _ = store.hasValue("example")
        _ = store.hasValue("example")
        #expect(store.readCount("example") == 0, "hasValue must never be implemented in terms of read")
    }

    @Test func readCountsEveryCallSoATestCanAssertLaziness() throws {
        let store = FakeSecretStore()
        try store.write("v", name: "example")
        #expect(store.readCount("example") == 0)
        _ = store.read("example")
        #expect(store.readCount("example") == 1)
        _ = store.read("example")
        #expect(store.readCount("example") == 2)
    }

    // MARK: - KeyProviding (GhostCLIClient's seam) resolves through the app-owned store

    @Test func keychainKeyProviderReadsThroughTheInjectedStore() throws {
        let store = FakeSecretStore()
        try store.write("sk-fake-key", name: "ai.openrouter")
        let provider = KeychainKeyProvider(store: store)
        #expect(provider.key(service: "ai.openrouter") == "sk-fake-key")
        #expect(provider.key(service: "ai.ghostcli") == nil)
    }

    // MARK: - Legacy reader: adoption only, never automatic

    @Test func legacyReaderReturnsTheSeededValue() {
        let legacy = FakeLegacySecretReader(values: ["OPENROUTER_API_KEY": "old-key"])
        #expect(legacy.readLegacy(service: "OPENROUTER_API_KEY", account: nil) == "old-key")
        #expect(legacy.readCount("OPENROUTER_API_KEY") == 1)
    }

    @Test func legacyExistsCheckNeverCountsAsARealRead() {
        let legacy = FakeLegacySecretReader(values: ["OPENROUTER_API_KEY": "old-key"])
        #expect(legacy.existsLegacy(service: "OPENROUTER_API_KEY", account: nil))
        #expect(legacy.readCount("OPENROUTER_API_KEY") == 0,
                "presence check must not be implemented in terms of the decrypting read")
    }

    @Test func legacyReaderMissingServiceReturnsNil() {
        let legacy = FakeLegacySecretReader()
        #expect(legacy.readLegacy(service: "kronos_mcp_token", account: "token") == nil)
        #expect(!legacy.existsLegacy(service: "kronos_mcp_token", account: "token"))
    }

    // MARK: - GhostCLIClient reads the key exactly once per request, through the injected fake

    @Test func ghostCLIClientReadsKeyOnceOnSendNeverBeforeOrAfterConstruction() async throws {
        let secretStore = FakeSecretStore()
        try secretStore.write("sk-fake", name: "ai.ghostcli")
        let keyProvider = KeychainKeyProvider(store: secretStore)
        let transport = FakeHTTPTransport(responseJSON: #"{"choices":[{"message":{"content":"{\"ok\":true}"}}]}"#)
        let client = GhostCLIClient(modelID: "claude-sonnet-5", keyProvider: keyProvider,
                                     keyService: "ai.ghostcli", transport: transport)
        // Constructing the client must not itself read anything.
        #expect(secretStore.readCount("ai.ghostcli") == 0)
        let request = AIRequest(model: "claude-sonnet-5", messages: [.user("hi")], kind: .triage,
                                 maxTokens: 100, budgetSeconds: 5)
        _ = try await client.send(request)
        #expect(secretStore.readCount("ai.ghostcli") == 1, "exactly one read for the first request")
        _ = try? await client.send(request)
        // GhostCLIClient does not cache internally (each call is a fresh struct-level send);
        // this documents that fact rather than asserting a cache that doesn't exist here —
        // the caching-after-first-read requirement belongs to the launch-path self-test's
        // MCPServer, which owns a token's lifetime across many requests.
        #expect(secretStore.readCount("ai.ghostcli") == 2)
    }

    // MARK: - No real store on the test path

    @Test func defaultRealStoreTypeIsNeverConstructedHere() {
        // Static, not runtime: every store built anywhere above in this file is a
        // `FakeSecretStore`/`FakeLegacySecretReader`. This test exists so that if a future
        // edit to this file ever adds `KeychainSecretStore()`/`KeychainLegacySecretReader()`
        // it stands out as a real Keychain touch and must be justified, not slipped in.
        let src = (try? String(contentsOfFile: #filePath, encoding: .utf8)) ?? ""
        let bodyOnly = src.components(separatedBy: "// MARK: - No real store on the test path").first ?? src
        #expect(!bodyOnly.contains("KeychainSecretStore()"))
        #expect(!bodyOnly.contains("KeychainLegacySecretReader()"))
    }
}

/// Never touches the network: returns a fixed response (or throws) from memory.
final class FakeHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let responseJSON: String
    init(responseJSON: String) { self.responseJSON = responseJSON }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                        httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        return (Data(responseJSON.utf8), response)
    }
}
