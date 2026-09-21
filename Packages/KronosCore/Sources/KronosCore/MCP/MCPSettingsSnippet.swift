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
}
