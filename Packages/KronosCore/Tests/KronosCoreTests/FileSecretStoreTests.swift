#if os(macOS)
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

    private func inode(_ url: URL) throws -> UInt64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }

    /// A rewrite replaces the file (new inode) instead of truncating it in place, so a reader that
    /// opens the path at any moment gets the complete old value or the complete new one.
    @Test func rewriteReplacesTheFileAtomically() throws {
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileSecretStore(directory: dir)
        try store.write("first-token", name: "mcp_token")
        let target = dir.appendingPathComponent("mcp_token")
        let before = try inode(target)
        try store.write("second-token", name: "mcp_token")
        #expect(try inode(target) != before, "an in-place truncate keeps the inode; a rename does not")
        #expect(store.read("mcp_token") == "second-token")
        let attrs = try FileManager.default.attributesOfItem(atPath: target.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    /// A reader polling while the file is rewritten many times never sees an empty or mixed file.
    /// Large values widen the window a truncate-then-write would leave open.
    @Test func aConcurrentReaderNeverSeesAnEmptyOrTornValue() throws {
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileSecretStore(directory: dir)
        let a = String(repeating: "A", count: 2_000_000)
        let b = String(repeating: "B", count: 2_000_000)
        try store.write(a, name: "mcp_token")

        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var bad = 0, reads = 0, stop = false
            func record(ok: Bool) { lock.lock(); reads += 1; if !ok { bad += 1 }; lock.unlock() }
            func halt() { lock.lock(); stop = true; lock.unlock() }
            var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stop }
            var snapshot: (bad: Int, reads: Int) { lock.lock(); defer { lock.unlock() }; return (bad, reads) }
        }
        let counter = Counter()
        let reader = Thread {
            while !counter.isStopped {
                let v = store.read("mcp_token")
                counter.record(ok: v == a || v == b)
            }
        }
        reader.start()
        for i in 0..<60 { try store.write(i.isMultiple(of: 2) ? b : a, name: "mcp_token") }
        counter.halt()
        Thread.sleep(forTimeInterval: 0.2)
        let result = counter.snapshot
        #expect(result.reads > 0, "the reader must have run")
        #expect(result.bad == 0, "\(result.bad) of \(result.reads) reads saw an empty or partial token")
    }

    @Test func noTempFileIsLeftBehind() throws {
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileSecretStore(directory: dir)
        for i in 0..<5 { try store.write("value-\(i)", name: "mcp_token") }
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names == ["mcp_token"], "only the secret itself may remain, got \(names)")
    }

    @Test func aFailedWriteLeavesTheOldValueAndNoTempFile() throws {
        let dir = scratch(); defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let store = FileSecretStore(directory: dir)
        try store.write("keep-me", name: "mcp_token")
        // Folder without write permission: the temp file cannot be created, so nothing may change.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        #expect(throws: (any Error).self) {
            try AtomicSecretFile.write(Data("lost".utf8), to: dir.appendingPathComponent("mcp_token"))
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        #expect(store.read("mcp_token") == "keep-me")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["mcp_token"])
    }

    @Test func endpointFileIsWrittenTheSameWay() throws {
        let dir = scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        try MCPEndpointFile.write(port: 47311, pid: 1234, bundleID: "com.example.test", directory: dir)
        let target = dir.appendingPathComponent(MCPEndpointFile.fileName)
        let before = try inode(target)
        try MCPEndpointFile.write(port: 47312, pid: 1234, bundleID: "com.example.test", directory: dir)
        #expect(try inode(target) != before)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: target)) as? [String: Any])
        #expect(json["port"] as? Int == 47312)
        let attrs = try FileManager.default.attributesOfItem(atPath: target.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == [MCPEndpointFile.fileName])
    }
}

#endif
