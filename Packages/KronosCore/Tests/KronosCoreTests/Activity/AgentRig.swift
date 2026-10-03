import Testing
import Foundation
import SwiftData
@testable import KronosCore

/// A store, an in-memory agent hub with a controllable clock, and a dispatcher wired to both.
@MainActor
final class AgentRig {
    let store: TaskStore
    let hub: AgentHub
    let dispatcher: MCPDispatcher
    var clock: Date
    let day: Int

    init(start: Date = Date(timeIntervalSince1970: 1_790_000_000)) throws {
        clock = start
        day = Day.from(start)
        store = try TaskStore(inMemory: true)
        let ctx = ModelContext(try KronosLocalStore.makeContainer(inMemory: true))
        let box = ClockBox(start)
        hub = AgentHub(context: ctx, tokenFiles: nil, now: { box.now })
        self.box = box
        let d = day
        dispatcher = MCPDispatcher(store: store, ranking: RankingEngine(), today: { d })
        dispatcher.hub = hub
    }

    private let box: ClockBox
    func advance(_ seconds: TimeInterval) { clock = clock.addingTimeInterval(seconds); box.now = clock }

    /// A registered agent's identity with the given scopes.
    func agent(_ slug: String, scopes: AgentScopes = .standard) -> AgentIdentity {
        let row = hub.register(slug: slug, scopes: scopes)
        hub.setScopes(scopes, slug: slug)
        return AgentHub.identity(of: row, legacy: false)
    }

    struct Reply {
        let isError: Bool
        let body: [String: Any]
        var code: String? { body["error"] as? String }
        var message: String { body["message"] as? String ?? "" }
        func str(_ k: String) -> String? { body[k] as? String }
    }

    @discardableResult
    func call(_ tool: String, _ args: [String: Any] = [:], as who: AgentIdentity? = nil, client: String? = nil) throws -> Reply {
        let rpc = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                                              "params": ["name": tool, "arguments": args]])
        let reply = dispatcher.handleBody(rpc, client: client, agent: who)
        let data = try #require(reply.body)
        let top = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let res = try #require(top["result"] as? [String: Any], "no result: \(String(decoding: data, as: UTF8.self))")
        return Reply(isError: (res["isError"] as? Bool) ?? false, body: res["structuredContent"] as? [String: Any] ?? [:])
    }

    func uuid(_ s: String?) throws -> UUID {
        let raw = try #require(s)
        return try #require(UUID(uuidString: raw))
    }

    func taskID(_ r: Reply) throws -> UUID {
        let t = try #require(r.body["task"] as? [String: Any])
        let raw = try #require(t["id"] as? String)
        return try #require(UUID(uuidString: raw))
    }
}

final class ClockBox: @unchecked Sendable {
    var now: Date
    init(_ d: Date) { now = d }
}
