// KronosCore/Secrets — the one seam every Keychain touch in the app goes through.
//
// Why this exists: the app used to read Keychain items it never created (a token written by
// an older build under an older code signature, a key written once years ago by the `security`
// CLI). macOS ties Keychain access to the exact binary that created an item; a rebuilt app is a
// different requester even with the same bundle id, so every launch asked the login password
// again. The fix is not "handle the prompt better" — it is: only ever read items this exact
// running app wrote itself. See `KeychainSecretStore` for how that plays out, and
// `LegacySecretReader` for the one-time, user-initiated exception that lets someone reuse a key
// they already had without retyping it.
public protocol SecretStoring: Sendable {
    /// The stored value for `name`, or nil if this app has never written one. Never throws —
    /// "not present" and "can't read right now" are both just nil to every caller; there is
    /// nothing a caller can usefully do differently between those two cases.
    func read(_ name: String) -> String?
    /// Stores `value` under `name`, replacing whatever was there.
    func write(_ value: String, name: String) throws
    /// Removes whatever is stored under `name`. A no-op if nothing was there.
    func delete(_ name: String)
    /// True once something has been written under `name` and not since deleted. Backed by a
    /// plain, non-secret flag — checking it never touches the Keychain, so a "do we have a key"
    /// UI check is free and can run on the main thread.
    func hasValue(_ name: String) -> Bool
}
