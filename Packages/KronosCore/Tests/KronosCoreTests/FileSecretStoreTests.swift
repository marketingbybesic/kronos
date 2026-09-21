import Foundation
import Testing
@testable import KronosCore

@Suite struct FileSecretStoreTests {
    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("kronos-secrets-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func roundTripAndUserOnlyPermissions() throws {
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileSecretStore(directory: dir)
        #expect(store.read("mcp_token") == nil)
        #expect(store.hasValue("mcp_token") == false)
        try store.write("abc123", name: "mcp_token")
        #expect(store.read("mcp_token") == "abc123")
        #expect(store.hasValue("mcp_token"))
        let file = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("mcp_token").path)
        #expect((file[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let folder = try FileManager.default.attributesOfItem(atPath: dir.path)
        #expect((folder[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        try store.write("second", name: "mcp_token")
        #expect(store.read("mcp_token") == "second")
        store.delete("mcp_token")
        #expect(store.read("mcp_token") == nil)
    }

    @Test func aNameIsNeverAPath() {
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileSecretStore(directory: dir)
        #expect(throws: (any Error).self) { try store.write("x", name: "../escape") }
        #expect(store.read("../escape") == nil)
        #expect(FileManager.default.fileExists(atPath: dir.deletingLastPathComponent().appendingPathComponent("escape").path) == false)
    }
}
