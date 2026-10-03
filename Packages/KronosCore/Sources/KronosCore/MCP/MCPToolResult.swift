#if os(macOS)
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

    /// A thrown outcome (see `decodeParams`) back as the result; anything else is INTERNAL.
    static func from(_ error: Error) -> MCPToolOutcome {
        (error as? MCPToolOutcome) ?? .error(.internalError, message: "\(error)")
    }

    /// INVALID_PARAMS naming the field a decode failed at, from the error's coding path.
    static func decodeFailure(_ e: DecodingError, tool: String) -> MCPToolOutcome {
        let context: DecodingError.Context
        var missing = false
        switch e {
        case .typeMismatch(_, let c), .dataCorrupted(let c), .valueNotFound(_, let c): context = c
        case .keyNotFound(let key, let c):
            context = DecodingError.Context(codingPath: c.codingPath + [key], debugDescription: c.debugDescription)
            missing = true
        @unknown default:
            return .error(.invalidParams, message: "could not decode \(tool) arguments")
        }
        let path = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
            .joined(separator: ".").replacingOccurrences(of: ".[", with: "[")
        let what = missing ? "required parameter `\(path)` is missing"
                           : "invalid value for `\(path.isEmpty ? "arguments" : path)`: \(context.debugDescription)"
        return .error(.invalidParams, message: "\(tool): \(what)", data: ["field": path])
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

extension MCPToolOutcome: Error {}

struct MCPToolCallEnvelope: Encodable {
    let content: [MCPContentBlock]
    let structuredContent: AnyEncodable
    let isError: Bool
}
#endif
