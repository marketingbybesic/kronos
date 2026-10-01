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

    /// Newest first. `initialize` echoes the client's version when it is one of these.
    public static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    /// Handles one already-parsed request. Returns `nil` when nothing is sent back: a
    /// notification (`notifications/*`, with or without an id) or a client response.
    public func handle(_ request: MCPRequest) -> MCPResponse? {
        if request.isClientResponse || request.method.hasPrefix("notifications/") { return nil }
        switch request.method {
        case "initialize":
            return .success(id: request.id, resultJSON: encode(initializeResult(for: request)))
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

    /// What the transport sends back for one HTTP body.
    public struct Reply: Sendable {
        public let status: Int          // 200, or 202 with no body
        public let body: Data?
        /// True when the body contained a tools/call that can change the store.
        public let mutated: Bool
    }

    /// Transport-independent: parses a body (single request or a batch array, which 2025-03-26
    /// allows and newer versions merely stop sending), dispatches, and returns the HTTP reply.
    public func handleBody(_ body: Data) -> Reply {
        let obj: Any
        do { obj = try JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) }
        catch { return Reply(status: 200, body: MCPResponse.failure(id: nil, .parseError).encoded(), mutated: false) }

        var mutated = false
        func one(_ o: Any) -> MCPResponse? {
            do {
                let req = try MCPRequest.parse(object: o)
                if isMutating(req) { mutated = true }
                return handle(req)
            } catch let e as MCPTransportError {
                return .failure(id: nil, e)
            } catch {
                return .failure(id: nil, .invalidRequest)
            }
        }
        if let batch = obj as? [Any] {
            if batch.isEmpty { return Reply(status: 200, body: MCPResponse.failure(id: nil, .invalidRequest).encoded(), mutated: false) }
            let replies = batch.compactMap(one).map { $0.encoded() }
            guard !replies.isEmpty else { return Reply(status: 202, body: nil, mutated: mutated) }
            var out = Data("[".utf8)
            out.append(replies.reduce(into: Data()) { acc, d in
                if !acc.isEmpty { acc.append(Data(",".utf8)) }
                acc.append(d)
            })
            out.append(Data("]".utf8))
            return Reply(status: 200, body: out, mutated: mutated)
        }
        guard let response = one(obj) else { return Reply(status: 202, body: nil, mutated: mutated) }
        return Reply(status: 200, body: response.encoded(), mutated: mutated)
    }

    /// Reads (list/get/ordo_get/rules_list) must not make the app refresh every list.
    private func isMutating(_ request: MCPRequest) -> Bool {
        guard request.method == "tools/call",
              let call = try? JSONDecoder().decode(ToolCallEnvelope.self, from: request.paramsData),
              let tool = MCPTool(rawValue: call.name) else { return false }
        switch tool {
        case .listTasks, .getTask, .ordoGet, .rulesList, .listProjects, .listAreas: return false
        default: return true
        }
    }

    private func handleToolsCall(_ request: MCPRequest) -> MCPResponse {
        guard let call = try? JSONDecoder().decode(ToolCallEnvelope.self, from: request.paramsData) else {
            return .failure(id: request.id, .invalidParams)
        }
        guard let tool = MCPTool(rawValue: call.name) else {
            return .invalidParams(id: request.id, message: "Unknown tool: \(call.name)")
        }
        let outcome = dispatch(tool, arguments: call.arguments ?? Data("{}".utf8))
        return .success(id: request.id, resultJSON: encode(outcome.envelope))
    }

    // MARK: - initialize / tools/list bodies

    private func initializeResult(for request: MCPRequest) -> [String: AnyEncodable] {
        let asked = (try? JSONSerialization.jsonObject(with: request.paramsData) as? [String: Any])?["protocolVersion"] as? String
        let version = asked.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil }
            ?? Self.supportedProtocolVersions[0]
        return [
            "protocolVersion": AnyEncodable(version),
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
        // NSNumber first: `0 as? Bool` / `1 as? Bool` succeed on Darwin, which turned every
        // 0 and 1 from JSONSerialization into false/true. Only a real CFBoolean is a Bool.
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { try container.encode(n.boolValue) }
            else if CFNumberIsFloatType(n) { try container.encode(n.doubleValue) }
            else { try container.encode(n.int64Value) }
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
