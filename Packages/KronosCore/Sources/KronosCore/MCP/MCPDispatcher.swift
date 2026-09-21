// MCP. Dispatches JSON-RPC methods (initialize, tools/list, tools/call,
// ping) onto the 13 alpha tools (Contracts/MCPTool.swift), against the same
// `TaskStoring` surface the app uses. Every mutating tool goes through the
// `…NoUndo` store variants so an MCP batch can never bury the user's own undo
// history (see TaskStoring.swift).
//
// Pure dispatch: no NWListener, no Keychain read, no AI call here (that lives
// in Kronos/MCP for the transport). This file is
// unit-testable with an in-memory TaskStore and no socket.

import Foundation

@MainActor
public final class MCPDispatcher {
    let store: any TaskStoring
    let ranking: any RankingProviding
    let today: () -> Int

    /// `ranking` is accepted for parity with the app's other Core consumers
    /// and future Alpha-2 tools (`impuls`, `dayplan_propose` — see
    /// Contracts/MCPTool.swift's deferred list); none of the current 13 tools
    /// call it, because ranking-over-MCP was cut in scope-12 (the MCP client
    /// is itself a model).
    public init(store: any TaskStoring,
               ranking: any RankingProviding,
               today: @escaping () -> Int = { Day.today() }) {
        self.store = store
        self.ranking = ranking
        self.today = today
    }

    // MARK: - JSON-RPC entry point

    /// Handles one already-parsed request. Returns `nil` for a notification
    /// (`id == nil`), which gets no reply per JSON-RPC 2.0.
    public func handle(_ request: MCPRequest) -> MCPResponse? {
        switch request.method {
        case "initialize":
            return .success(id: request.id, resultJSON: encode(initializeResult()))
        case "notifications/initialized":
            return nil
        case "ping":
            return .success(id: request.id, resultJSON: Data("{}".utf8))
        case "tools/list":
            return .success(id: request.id, resultJSON: encode(toolsListResult()))
        case "tools/call":
            return handleToolsCall(request)
        default:
            return .failure(id: request.id, .methodNotFound)
        }
    }

    private func handleToolsCall(_ request: MCPRequest) -> MCPResponse {
        guard let call = try? JSONDecoder().decode(ToolCallEnvelope.self, from: request.paramsData) else {
            return .failure(id: request.id, .invalidParams)
        }
        guard let tool = MCPTool(rawValue: call.name) else {
            return .failure(id: request.id, .methodNotFound)
        }
        let outcome = dispatch(tool, arguments: call.arguments ?? Data("{}".utf8))
        return .success(id: request.id, resultJSON: encode(outcome.envelope))
    }

    // MARK: - initialize / tools/list bodies

    private func initializeResult() -> [String: AnyEncodable] {
        [
            "protocolVersion": AnyEncodable("2025-06-18"),
            "capabilities": AnyEncodable(["tools": ["listChanged": false]]),
            "serverInfo": AnyEncodable(["name": "kronos", "title": "Kronos", "version": "0.1.0"]),
            "instructions": AnyEncodable(
                "Kronos is the user's task manager. Use list_tasks with a view filter before " +
                "guessing ids. Never invent UUIDs. create_task fields you pass explicitly " +
                "are never overwritten by auto-triage."
            )
        ]
    }

    private func toolsListResult() -> [String: [ToolListEntry]] {
        ["tools": MCPTool.allCases.map { tool in
            ToolListEntry(name: tool.name,
                          description: tool.toolDescription,
                          inputSchemaRaw: tool.jsonSchema)
        }]
    }

    // MARK: - encoding helpers

    private func encode<T: Encodable>(_ value: T) -> Data {
        (try? MCPJSON.encoder.encode(value)) ?? Data("{}".utf8)
    }
}

// MARK: - tools/call envelope

private struct ToolCallEnvelope: Decodable {
    let name: String
    let arguments: Data?

    enum CodingKeys: String, CodingKey { case name, arguments }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        if let obj = try c.decodeIfPresent(AnyDecodableBox.self, forKey: .arguments) {
            arguments = try JSONSerialization.data(withJSONObject: obj.value)
        } else {
            arguments = nil
        }
    }
}

/// A tool's `tools/list` entry. `inputSchemaRaw` is re-parsed at encode time
/// because `MCPTool.jsonSchema` is a string literal (kept readable in one
/// place, MCPToolTests.everySchemaParses asserts it is valid JSON).
private struct ToolListEntry: Encodable {
    let name: String
    let description: String
    let inputSchemaRaw: String

    enum CodingKeys: String, CodingKey { case name, description, inputSchema }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(description, forKey: .description)
        let obj = (try? JSONSerialization.jsonObject(with: Data(inputSchemaRaw.utf8))) ?? [String: Any]()
        try c.encode(AnyEncodable(obj), forKey: .inputSchema)
    }
}

/// Minimal `Encodable` wrapper over a JSONSerialization-shaped `Any`
/// (dictionaries/arrays/strings/numbers/bools/NSNull), needed because the
/// tool schemas and the initialize/tools-list bodies are built from loosely
/// typed literals rather than dedicated Codable structs.
struct AnyEncodable: Encodable {
    let value: Any
    init(_ value: Any) { self.value = value }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let v as String: try container.encode(v)
        case let v as Bool: try container.encode(v)
        case let v as Int: try container.encode(v)
        case let v as Double: try container.encode(v)
        case let v as [String: Any]:
            var keyed = encoder.container(keyedBy: DynamicKey.self)
            for (k, v) in v { try keyed.encode(AnyEncodable(v), forKey: DynamicKey(stringValue: k)!) }
        case let v as [Any]:
            var unkeyed = encoder.unkeyedContainer()
            for item in v { try unkeyed.encode(AnyEncodable(item)) }
        case let v as [String: AnyEncodable]:
            var keyed = encoder.container(keyedBy: DynamicKey.self)
            for (k, v) in v { try keyed.encode(v, forKey: DynamicKey(stringValue: k)!) }
        case is NSNull:
            try container.encodeNil()
        default:
            try container.encodeNil()
        }
    }
}

private struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
    init?(intValue: Int) { self.stringValue = "\(intValue)"; self.intValue = intValue }
}

/// Decodes an arbitrary JSON value into a JSONSerialization-compatible `Any`.
private struct AnyDecodableBox: Decodable {
    let value: Any
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { value = v; return }
        if let v = try? c.decode(Double.self) { value = v; return }
        if let v = try? c.decode(String.self) { value = v; return }
        if let v = try? c.decode([String: AnyDecodableBox].self) {
            value = v.mapValues { $0.value }; return
        }
        if let v = try? c.decode([AnyDecodableBox].self) { value = v.map { $0.value }; return }
        value = NSNull()
    }
}
