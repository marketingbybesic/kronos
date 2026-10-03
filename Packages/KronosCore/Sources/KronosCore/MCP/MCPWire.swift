#if os(macOS)
// MCP. JSON-RPC 2.0 framing. Pure value types, no Network.framework here
// so this file is unit-testable without a socket.
//
// Kronos serves exactly one method surface: initialize, tools/list, tools/call,
// ping. Everything else is -32601 (unknown tool names are -32602). A malformed request body is -32700 (parse
// error) or -32600 (invalid request) per the JSON-RPC 2.0 spec.

import Foundation

/// A decoded JSON-RPC 2.0 request. `id` is `nil` for a notification
/// (`notifications/initialized`), which gets no reply.
public struct MCPRequest: Sendable {
    public let jsonrpc: String
    public let id: MCPRequestID?
    public let method: String
    /// Raw params object, re-decoded per-method by the dispatcher. Kept as
    /// `Data` rather than `[String: Any]` so it stays `Sendable`.
    public let paramsData: Data

    public init(jsonrpc: String = "2.0", id: MCPRequestID?, method: String, paramsData: Data) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.method = method
        self.paramsData = paramsData
    }

    /// True for a client RESPONSE to a server request (no `method`; has result/error). Kronos
    /// never sends server requests, so these are accepted and dropped (HTTP 202).
    public var isClientResponse: Bool { method.isEmpty }

    /// Parses a single JSON-RPC request from a raw body. Throws
    /// `MCPTransportError.parseError` for invalid JSON and `.invalidRequest`
    /// for valid JSON that is not a JSON-RPC 2.0 request object.
    public static func parse(_ body: Data) throws -> MCPRequest {
        let obj: Any
        do {
            obj = try JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed])
        } catch {
            throw MCPTransportError.parseError
        }
        return try parse(object: obj)
    }

    /// Same, from an already-decoded JSON value (one element of a batch).
    public static func parse(object obj: Any) throws -> MCPRequest {
        guard let dict = obj as? [String: Any] else { throw MCPTransportError.invalidRequest }
        // The spec requires the literal "2.0"; a missing member is not "2.0".
        guard dict["jsonrpc"] as? String == "2.0" else { throw MCPTransportError.invalidRequest }
        var id: MCPRequestID?
        if let raw = dict["id"], !(raw is NSNull) {
            guard let parsed = MCPRequestID(any: raw) else { throw MCPTransportError.invalidRequest }
            id = parsed
        }
        guard let method = dict["method"] as? String, !method.isEmpty else {
            if dict["method"] == nil, dict["result"] != nil || dict["error"] != nil {
                return MCPRequest(id: id, method: "", paramsData: Data("{}".utf8))
            }
            throw MCPTransportError.invalidRequest
        }
        var paramsData = Data("{}".utf8)
        if let params = dict["params"] {
            paramsData = (try? JSONSerialization.data(withJSONObject: params)) ?? paramsData
        }
        return MCPRequest(jsonrpc: "2.0", id: id, method: method, paramsData: paramsData)
    }
}

/// JSON-RPC ids are a string, a number, or absent (notification). Modelled as
/// its own type rather than `AnyCodable` so equality and encoding are exact.
public enum MCPRequestID: Sendable, Equatable {
    case number(Int)
    case string(String)

    /// Int keeps full precision (a Double loses ids above 2^53). Bool is an NSNumber too:
    /// `true` must not become id 1, and a fractional id is not a valid id here.
    init?(any: Any?) {
        switch any {
        case let n as NSNumber:
            guard CFGetTypeID(n) != CFBooleanGetTypeID(), !CFNumberIsFloatType(n) else { return nil }
            self = .number(n.intValue)
        case let s as String:   self = .string(s)
        default:                return nil
        }
    }

    var jsonValue: Any {
        switch self {
        case .number(let i): return i
        case .string(let s): return s
        }
    }
}

/// Transport-level failures: JSON-RPC `-32xxx` errors, sent instead of a
/// `result`. Tool-level failures (a missing task) are NOT this — those ride
/// inside a successful result with `isError: true` (see `MCPToolError`).
public enum MCPTransportError: Int, Error, Sendable {
    case parseError      = -32700
    case invalidRequest  = -32600
    case methodNotFound  = -32601
    case invalidParams   = -32602
    case notInitialized  = -32002

    public var message: String {
        switch self {
        case .parseError:     return "Parse error"
        case .invalidRequest: return "Invalid Request"
        case .methodNotFound: return "Method not found"
        case .invalidParams:  return "Invalid params"
        case .notInitialized: return "Server not initialized"
        }
    }
}

/// A JSON-RPC 2.0 response, encoded by hand: the payload is a `result` OR an
/// `error`, and `Codable` cannot express that either/or cleanly over `Any`.
public struct MCPResponse: Sendable {
    public let id: MCPRequestID?
    public let result: Data?     // pre-encoded JSON object bytes
    public let error: (code: Int, message: String)?

    public static func success(id: MCPRequestID?, resultJSON: Data) -> MCPResponse {
        MCPResponse(id: id, result: resultJSON, error: nil)
    }

    /// `-32602` with a specific message (e.g. the unknown tool name).
    public static func invalidParams(id: MCPRequestID?, message: String) -> MCPResponse {
        MCPResponse(id: id, result: nil, error: (MCPTransportError.invalidParams.rawValue, message))
    }

    public static func failure(id: MCPRequestID?, _ error: MCPTransportError) -> MCPResponse {
        MCPResponse(id: id, result: nil, error: (error.rawValue, error.message))
    }

    /// Serialises to the wire JSON object. `id` is `null` when the request
    /// carried none (e.g. it failed to parse before an id was known).
    public func encoded() -> Data {
        var obj: [String: Any] = ["jsonrpc": "2.0"]
        obj["id"] = id?.jsonValue ?? NSNull()
        if let error {
            obj["error"] = ["code": error.code, "message": error.message]
        } else if let result {
            let parsed = (try? JSONSerialization.jsonObject(with: result, options: [.fragmentsAllowed])) ?? [String: Any]()
            obj["result"] = parsed
        }
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
    }
}
#endif
