// MCP. The `tools/call` result envelope: every tool
// returns `{"content":[{"type":"text","text":"<json>"}],"structuredContent":
// <object>,"isError":bool}`. `structuredContent` is authoritative; `text`
// carries the identical bytes for clients without structured-output support.

import Foundation

struct MCPContentBlock: Encodable {
    let type = "text"
    let text: String
}

/// What one tool call produced, before it is wrapped in the content
/// envelope. `body` is anything Encodable — each tool builds its own
/// response struct.
struct MCPToolOutcome {
    let body: Data          // pre-encoded JSON object
    let isError: Bool

    static func ok<T: Encodable>(_ value: T) -> MCPToolOutcome {
        MCPToolOutcome(body: (try? MCPJSON.encoder.encode(value)) ?? Data("{}".utf8), isError: false)
    }

    static func error(_ code: MCPToolError, message: String, data: [String: Any]? = nil) -> MCPToolOutcome {
        var obj: [String: Any] = ["error": code.rawValue, "message": message]
        if let data { obj["data"] = data }
        let body = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        return MCPToolOutcome(body: body, isError: true)
    }

    /// The full `tools/call` envelope for this outcome.
    var envelope: MCPToolCallEnvelope {
        let text = String(data: body, encoding: .utf8) ?? "{}"
        let structured = (try? JSONSerialization.jsonObject(with: body)) ?? [String: Any]()
        return MCPToolCallEnvelope(content: [MCPContentBlock(text: text)],
                                   structuredContent: AnyEncodable(structured),
                                   isError: isError)
    }
}

struct MCPToolCallEnvelope: Encodable {
    let content: [MCPContentBlock]
    let structuredContent: AnyEncodable
    let isError: Bool
}
