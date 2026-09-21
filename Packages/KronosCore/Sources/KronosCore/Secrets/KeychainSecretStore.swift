// KronosCore/Secrets. Real, file-Keychain-backed `SecretStoring`.
//
// One service for everything this app writes itself (`com.besic.kronos.secret`), account =
// the logical name passed in. No access group, no `kSecUseDataProtectionKeychain`: both need a
// Developer Team (they fail -34018 without one, same reasoning as the legacy MCP item this
// replaces). `.afterFirstUnlock` rather than `.whenUnlocked` because a background read (the MCP
// listener answering a request while the screen is locked) should not fail just because nobody
// is at the keyboard.
//
// The item this type creates is readable, with no prompt, by every later build signed with the
// same certificate — because it is an item THIS app created. An item some other build or the
// `security` CLI created is a different story: see `LegacySecretReader`, which this type
// deliberately does not touch.
import Foundation
import Security

public struct KeychainSecretStore: SecretStoring {
    private static let service = "com.besic.kronos.secret"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func read(_ name: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: name,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            // The item is gone (removed in Keychain Access, another Mac's defaults restored here):
            // stop telling the UI a key exists. Any OTHER failure (locked keychain, denied) says
            // nothing about existence, so the flag is left alone.
            if status == errSecItemNotFound { defaults.set(false, forKey: Self.hasKeyDefaultsKey(name)) }
            return nil
        }
        return value
    }

    public func write(_ value: String, name: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: name
        ]
        // Update in place first: delete-then-add would lose the stored key if the add failed.
        let data = Data(value.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SecretStoreError.writeFailed(status) }
        defaults.set(true, forKey: Self.hasKeyDefaultsKey(name))
    }

    public func delete(_ name: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: name
        ]
        SecItemDelete(query as CFDictionary)
        defaults.removeObject(forKey: Self.hasKeyDefaultsKey(name))
    }

    /// Never touches the Keychain: reads the flag `write`/`delete` above maintain. If the flag
    /// was never set (e.g. this app has never written that name in this UserDefaults domain,
    /// such as after a snapshot-mode run or a fresh install) this falls back to one real read
    /// so it is never wrong, only sometimes not free.
    public func hasValue(_ name: String) -> Bool {
        if defaults.object(forKey: Self.hasKeyDefaultsKey(name)) != nil {
            return defaults.bool(forKey: Self.hasKeyDefaultsKey(name))
        }
        let has = read(name) != nil
        defaults.set(has, forKey: Self.hasKeyDefaultsKey(name))
        return has
    }

    private static func hasKeyDefaultsKey(_ name: String) -> String {
        "kronos.secret.has.\(name)"
    }
}

public enum SecretStoreError: Error {
    case writeFailed(OSStatus)
}
