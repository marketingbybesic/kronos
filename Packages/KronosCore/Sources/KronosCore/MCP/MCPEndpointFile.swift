// MCP discovery. The bridge (and any harness) finds the running server through
// `<secrets dir>/mcp_endpoint.json`, 0600, per bundle (the demo has its own folder, so it never
// touches a user's). It holds NO token: the token already sits beside it in `mcp_token`.
// The old ~/.kronos-mcp.json put the token in a world-readable home-directory file.
import Foundation

public enum MCPEndpointFile {
    public static let fileName = "mcp_endpoint.json"

    /// Same folder as `FileSecretStore()`'s default, so the two always sit together.
    public static func defaultDirectory(bundleID: String? = Bundle.main.bundleIdentifier) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent(KronosStore.folderName(bundleID: bundleID), isDirectory: true)
            .appendingPathComponent("secrets", isDirectory: true)
    }

    public static func contents(port: Int, pid: Int32, bundleID: String) -> Data {
        let dict: [String: Any] = ["port": port, "pid": Int(pid), "bundleId": bundleID,
                                   "url": "http://127.0.0.1:\(port)/mcp"]
        return (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    /// Same order as FileSecretStore.write: create 0600 BEFORE the content goes in.
    public static func write(port: Int, pid: Int32 = ProcessInfo.processInfo.processIdentifier,
                             bundleID: String, directory: URL) throws {
        let fm = FileManager.default
        let url = directory.appendingPathComponent(fileName)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try contents(port: port, pid: pid, bundleID: bundleID).write(to: url, options: [])
    }

    public static func remove(directory: URL) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName))
    }

    /// Deletes the legacy ~/.kronos-mcp.json (it carried the bearer token).
    public static func removeLegacy(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        try? FileManager.default.removeItem(at: home.appendingPathComponent(".kronos-mcp.json"))
    }

    // MARK: - Origin check (DNS rebinding / browser pages)

    /// No Origin (curl, bridge, SDK clients) is allowed; a browser page is allowed only when it is
    /// itself served from loopback (or `null`, a file/sandboxed page). Anything else is 403.
    public static func isOriginAllowed(_ origin: String?) -> Bool {
        guard let origin else { return true }
        if origin == "null" { return true }
        for host in ["http://127.0.0.1", "http://localhost"] {
            if origin == host { return true }
            if origin.hasPrefix(host + ":"), UInt16(origin.dropFirst(host.count + 1)) != nil { return true }
        }
        return false
    }
}
