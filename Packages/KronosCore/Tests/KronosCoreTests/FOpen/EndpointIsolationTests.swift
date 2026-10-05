#if os(macOS)
import Testing
import Foundation
@testable import KronosCore

/// A live test or snapshot run has the installed app's bundle id; its MCP discovery file must stay in its own scratch
/// store, never in the real Application Support folder.
@Suite(.serialized) struct EndpointIsolationTests {

    private func withEnv(_ values: [String: String?], _ body: () -> Void) {
        var saved: [String: String?] = [:]
        for (key, value) in values {
            saved[key] = ProcessInfo.processInfo.environment[key]
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
        body()
        for (key, value) in saved {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
    }

    @Test func aHermeticRunKeepsItsEndpointFileInItsOwnStore() {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("kronos-endpoint-\(UUID().uuidString)").path
        withEnv(["KRONOS_STORE_DIR": scratch, "KRONOS_UITEST": nil, "KRONOS_SNAPSHOT": nil]) {
            let dir = MCPEndpointFile.defaultDirectory(bundleID: "com.besic.kronos")
            #expect(dir.lastPathComponent == "secrets")
            #expect(dir.deletingLastPathComponent().standardizedFileURL.path.hasSuffix(URL(fileURLWithPath: scratch).standardizedFileURL.lastPathComponent))
            #expect(!dir.path.contains("Application Support"))
        }
    }

    // Positive control: with no scratch store the same call lands in the real Application Support folder, so the
    // test above can only pass because of the isolation.
    @Test func aPlainRunStillUsesApplicationSupport() {
        withEnv(["KRONOS_STORE_DIR": nil, "KRONOS_UITEST": nil, "KRONOS_SNAPSHOT": nil]) {
            let dir = MCPEndpointFile.defaultDirectory(bundleID: "com.besic.kronos")
            #expect(dir.path.hasSuffix("Application Support/Kronos/secrets"))
        }
    }
}

#endif
