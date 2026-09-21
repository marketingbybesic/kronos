// KronosCore/Secrets. Reads a Keychain item this app did NOT create, under whatever service
// name an older build (or the `security` CLI) used. Used for exactly one thing: the user's own
// "Use the key already in your Keychain" action in Settings, which macOS will ask about once
// (the user approves that single dialog themselves) — never called from any launch or
// background path. Read-only: nothing here ever deletes or renames a legacy item, because
// scripts outside the app (`triage-eval.mjs`, `capture-eval.mjs`) read some of these same
// services directly and must keep working regardless of what the app does with its own copy.
import Foundation
import Security

public protocol LegacySecretReading: Sendable {
    /// `service` is the legacy Keychain service name, e.g. "OPENROUTER_API_KEY". `account`
    /// matches whatever that item was originally written with — several legacy items here
    /// have no account at all (nil), which is a valid, distinct Keychain query from account "".
    /// Decrypts the value, which is what raises macOS's "allow access" dialog the first time —
    /// call this ONLY from the user's own adopt action, never to just check presence.
    func readLegacy(service: String, account: String?) -> String?
    /// Whether an item exists under `service`/`account`, WITHOUT decrypting it. A query that
    /// asks for no data back (no `kSecReturnData`) only checks the item's existence and does
    /// not raise the access-control dialog — safe to call to decide whether to show the
    /// "Use the key already in your Keychain" row at all.
    func existsLegacy(service: String, account: String?) -> Bool
}

public struct KeychainLegacySecretReader: LegacySecretReading {
    public init() {}

    public func readLegacy(service: String, account: String?) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let account { query[kSecAttrAccount as String] = account }
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    public func existsLegacy(service: String, account: String?) -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let account { query[kSecAttrAccount as String] = account }
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
}

/// Fake for tests: never calls Security framework functions.
public final class FakeLegacySecretReader: LegacySecretReading, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    private var reads: [String] = []
    private var existsChecks: [String] = []

    public init(values: [String: String] = [:]) {
        self.values = values
    }

    public func readLegacy(service: String, account: String?) -> String? {
        lock.lock(); defer { lock.unlock() }
        reads.append(service)
        return values[service]
    }

    public func existsLegacy(service: String, account: String?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        existsChecks.append(service)
        return values[service] != nil
    }

    public func readCount(_ service: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return reads.filter { $0 == service }.count
    }

    public func existsCheckCount(_ service: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return existsChecks.filter { $0 == service }.count
    }
}
