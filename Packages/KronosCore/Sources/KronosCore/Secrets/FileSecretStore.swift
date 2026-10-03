// KronosCore/Secrets/FileSecretStore — a secret kept in a file only this user can read.
//
// Why not the Keychain for everything: macOS scopes a Keychain item to a "partition". An app
// signed with an Apple team gets `teamid:…`, which survives updates. An app signed ad hoc or with
// a local certificate gets `cdhash:…`, the hash of that exact binary, so EVERY new build is a
// stranger to the item the previous build wrote and the login-password dialog comes back after
// each update (measured: an item written by one build, read by the next, same certificate, same
// designated requirement). Until the app ships under a Developer ID, the only way to never show
// that dialog is to not put app-generated secrets in the Keychain.
//
// What may live here: secrets the APP generates and that guard nothing beyond what the user's own
// account can already reach. The MCP bearer token is the case: it keeps other local processes off
// the loopback server, and a process running as this user can already open the task database
// directly. A key with value outside this Mac (an AI provider key) stays in the Keychain.
import Foundation

public struct FileSecretStore: SecretStoring {
    private let directory: URL

    /// Default: `~/Library/Application Support/Kronos/secrets`, mode 0700; each file 0600.
    public init(directory: URL? = nil) {
        if let directory { self.directory = directory; return }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        self.directory = base
            .appendingPathComponent(KronosStore.folderName(bundleID: Bundle.main.bundleIdentifier), isDirectory: true)
            .appendingPathComponent("secrets", isDirectory: true)
    }

    /// Names are fixed identifiers chosen by the app; anything else is refused rather than
    /// turned into a path.
    private func url(_ name: String) -> URL? {
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { return nil }
        return directory.appendingPathComponent(name)
    }

    public func read(_ name: String) -> String? {
        guard let url = url(name), let data = try? Data(contentsOf: url),
              let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }

    public func write(_ value: String, name: String) throws {
        guard let url = url(name) else { throw CocoaError(.fileWriteInvalidFileName) }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        // 0600 from creation and one rename over the old file: a reader sees the old value or the
        // new one, never an empty or partial file (AtomicSecretFile).
        try AtomicSecretFile.write(Data(value.utf8), to: url)
    }

    public func delete(_ name: String) {
        if let url = url(name) { try? FileManager.default.removeItem(at: url) }
    }

    public func hasValue(_ name: String) -> Bool {
        guard let url = url(name) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }
}
