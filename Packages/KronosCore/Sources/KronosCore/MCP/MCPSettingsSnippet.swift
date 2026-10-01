// MCP. The exact copy-paste snippets Settings -> Data shows for wiring
// an MCP client to the loopback server. The token
// is injected by the caller (read from Keychain at render time) and is never
// baked into a string constant here.

import Foundation

public enum MCPSettingsSnippet {
    /// `claude mcp add` command line, ready to paste into a terminal.
    public static func claudeCLI(token: String, port: Int = 47311) -> String {
        """
        claude mcp add --transport http kronos http://127.0.0.1:\(port)/mcp \\
          --header "Authorization: Bearer \(token)"
        """
    }

    /// JSON block for clients that take a URL-based server config directly.
    public static func genericJSON(token: String, port: Int = 47311) -> String {
        """
        { "mcpServers": { "kronos": {
            "url": "http://127.0.0.1:\(port)/mcp",
            "headers": { "Authorization": "Bearer \(token)" } } } }
        """
    }

    // MARK: - Bridge (kronos-mcp): what Settings shows now. No token, no port: the bridge reads
    // both from the app's own secrets folder, so a regenerated token or a moved port never
    // breaks a configured client. `bridge` is Kronos.app/Contents/MacOS/kronos-mcp.

    /// JSON string literal, which is also a valid TOML basic string and a valid YAML scalar.
    private static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    public static func bridgeClaudeCode(bridge: String, name: String = "kronos") -> String {
        "claude mcp add -s user \(name) -- \(quoted(bridge))"
    }

    public static func bridgeCodexTOML(bridge: String, name: String = "kronos") -> String {
        "[mcp_servers.\(name)]\ncommand = \(quoted(bridge))"
    }

    public static func bridgeHermesYAML(bridge: String, name: String = "kronos") -> String {
        "mcp_servers:\n  \(name):\n    command: \(quoted(bridge))"
    }

    public static func bridgeDesktopJSON(bridge: String, name: String = "kronos") -> String {
        "{ \"mcpServers\": { \"\(name)\": { \"command\": \(quoted(bridge)) } } }"
    }
}
