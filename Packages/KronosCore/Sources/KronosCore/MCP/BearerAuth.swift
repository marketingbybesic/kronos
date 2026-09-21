// L4 — MCP. Bearer token check over a raw `Authorization` header string, so
// the HTTP transport (Kronos/MCP, Network.framework) can call one pure
// function instead of re-parsing "Bearer <token>" itself.

import Foundation

public enum BearerAuth {
    private static let prefix = "Bearer "

    /// `header` is the raw `Authorization` header value, or nil when the
    /// request carried none. `expectedToken` is the token from Keychain.
    /// Missing header, wrong scheme, or wrong token are all rejected the
    /// same way — the spec draws no distinction (§1.5: "Missing or wrong").
    public static func isAuthorized(header: String?, expectedToken: String) -> Bool {
        guard let header, header.hasPrefix(prefix) else { return false }
        let presented = String(header.dropFirst(prefix.count))
        return ConstantTime.equals(presented, expectedToken)
    }
}
