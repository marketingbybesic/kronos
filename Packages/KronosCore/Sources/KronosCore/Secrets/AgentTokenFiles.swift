// One bearer token per agent, kept as `<secrets>/agents/<slug>.token` (0600, folder 0700). The
// app stores only the SHA-256 of a token in its agent row; the file is what the bridge reads.
// Same trade as the shared token (see FileSecretStore): a user-only file, not the Keychain.

import Foundation
import CryptoKit

public struct AgentTokenFiles: Sendable {
    public let directory: URL

    /// `secretsDirectory` is the folder that holds `mcp_token`; tokens go in its `agents/` child.
    public init(secretsDirectory: URL) {
        directory = secretsDirectory.appendingPathComponent("agents", isDirectory: true)
    }

    /// The same folder as the shared token, unless `KRONOS_STORE_DIR` points elsewhere (the
    /// bridge honours that variable too, so both ends agree in a hermetic run).
    public static func standard() -> AgentTokenFiles {
        if let o = ProcessInfo.processInfo.environment["KRONOS_STORE_DIR"], !o.isEmpty {
            return AgentTokenFiles(secretsDirectory: URL(fileURLWithPath: o, isDirectory: true)
                .appendingPathComponent("secrets", isDirectory: true))
        }
        return AgentTokenFiles(secretsDirectory: MCPEndpointFolder.defaultSecretsDirectory())
    }

    /// Lowercase letters, digits and dashes, 1 to 32 characters, no leading dash.
    public static func isValidSlug(_ slug: String) -> Bool {
        guard (1...32).contains(slug.count), slug.first != "-" else { return false }
        return slug.allSatisfy { ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "-" }
    }

    /// A display name or client name made into a slug ("Claude Code" gives "claude-code").
    public static func slug(from raw: String) -> String? {
        var out = ""
        for ch in raw.lowercased() {
            if (ch >= "a" && ch <= "z") || (ch >= "0" && ch <= "9") { out.append(ch) }
            else if !out.isEmpty, out.last != "-" { out.append("-") }
        }
        while out.last == "-" { out.removeLast() }
        out = String(out.prefix(32))
        while out.last == "-" { out.removeLast() }
        return isValidSlug(out) ? out : nil
    }

    func url(_ slug: String) -> URL? {
        Self.isValidSlug(slug) ? directory.appendingPathComponent(slug + ".token") : nil
    }

    public func read(_ slug: String) -> String? {
        guard let url = url(slug), let data = try? Data(contentsOf: url),
              let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else { return nil }
        return s
    }

    public func write(_ token: String, slug: String) throws {
        guard let url = url(slug) else { throw CocoaError(.fileWriteInvalidFileName) }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try AtomicSecretFile.write(Data(token.utf8), to: url)
    }

    public func delete(_ slug: String) {
        if let url = url(slug) { try? FileManager.default.removeItem(at: url) }
    }

    /// Slugs that have a token file, sorted.
    public func allSlugs() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".token") }
            .map { String($0.dropLast(".token".count)) }
            .filter(Self.isValidSlug)
            .sorted()
    }

    // MARK: - Token values

    /// 32 random bytes, base64url without padding; nil when the system RNG fails (never a weaker source).
    public static func generateToken() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Lowercase hex SHA-256 of a token: the only form the agent row keeps.
    public static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// The default secrets folder, shared by the shared token, the endpoint file and agent tokens.
enum MCPEndpointFolder {
    static func defaultSecretsDirectory(bundleID: String? = Bundle.main.bundleIdentifier) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent(KronosStore.folderName(bundleID: bundleID), isDirectory: true)
            .appendingPathComponent("secrets", isDirectory: true)
    }
}
