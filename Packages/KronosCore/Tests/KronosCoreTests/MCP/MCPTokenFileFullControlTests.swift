#if os(macOS)
import Testing
import Foundation
import SwiftData
@testable import KronosCore

/// Every agent in the Agents pane can hold Full control (write.all), including one that exists only
/// because Connect all wrote its token file (pi): the grant persists and is enforced for its token.
@MainActor
@Suite struct MCPTokenFileFullControlTests {

    private func files() -> AgentTokenFiles {
        AgentTokenFiles(secretsDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("kronos-fullctl-\(UUID().uuidString)"))
    }

    private func rig(_ files: AgentTokenFiles) throws -> (hub: AgentHub, store: TaskStore, dispatcher: MCPDispatcher) {
        let hub = AgentHub(context: ModelContext(try KronosLocalStore.makeContainer(inMemory: true)), tokenFiles: files)
        let store = try TaskStore(inMemory: true)
        let day = Day.from(Date(timeIntervalSince1970: 1_790_000_000))
        let d = MCPDispatcher(store: store, ranking: RankingEngine(), today: { day })
        d.hub = hub
        return (hub, store, d)
    }

    private func identity(_ hub: AgentHub, token: String) throws -> AgentIdentity {
        guard case .agent(let id) = hub.authenticate(bearer: token, legacyToken: "shared", client: "pi") else {
            Issue.record("token not accepted"); throw CocoaError(.fileReadNoPermission)
        }
        return id
    }

    private func update(_ d: MCPDispatcher, _ id: UUID, as who: AgentIdentity) throws -> (isError: Bool, code: String?) {
        let rpc = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "update_task", "arguments": ["id": id.uuidString, "title": "By pi"]]] as [String: Any])
        let data = try #require(d.handleBody(rpc, client: "pi", agent: who).body)
        let top = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let res = try #require(top["result"] as? [String: Any])
        let body = res["structuredContent"] as? [String: Any] ?? [:]
        return ((res["isError"] as? Bool) ?? false, body["error"] as? String)
    }

    @Test func aTokenFileAgentIsListedWithItsOwnTokenAndTheGrantPersists() throws {
        let f = files()
        let (hub, _, _) = try rig(f)
        let token = try #require(AgentTokenFiles.generateToken())
        try f.write(token, slug: "pi")                       // what Connect all does
        #expect(hub.agent(slug: "pi") == nil)
        #expect(hub.adoptTokenFiles())
        let row = try #require(hub.agent(slug: "pi"))
        #expect(row.tokenHash == AgentTokenFiles.hash(token) && !row.tokenHash.isEmpty)
        #expect(!hub.adoptTokenFiles(), "second pass changes nothing")

        var s = AgentScopes(csv: row.scopesRaw)
        s.set.insert(.writeAll); hub.setScopes(s, slug: "pi")
        #expect(AgentScopes(csv: try #require(hub.agent(slug: "pi")).scopesRaw).has(.writeAll))
        #expect(try identity(hub, token: token).scopes.has(.writeAll))

        s.set.remove(.writeAll); hub.setScopes(s, slug: "pi")
        #expect(!AgentScopes(csv: try #require(hub.agent(slug: "pi")).scopesRaw).has(.writeAll))
        #expect(try !identity(hub, token: token).scopes.has(.writeAll))
    }

    @Test func aRowRegisteredThroughTheSharedTokenTakesTheTokenFileOnAdopt() throws {
        let f = files()
        let (hub, _, _) = try rig(f)
        // pi first connected with the shared token: a row without a hash, legacy rights.
        _ = hub.authenticate(bearer: "shared", legacyToken: "shared", client: "pi")
        let before = try #require(hub.agent(slug: "pi"))
        #expect(before.tokenHash.isEmpty && AgentScopes(csv: before.scopesRaw) == .legacy)

        let token = try #require(AgentTokenFiles.generateToken())
        try f.write(token, slug: "pi")
        #expect(hub.adoptTokenFiles())
        let after = try #require(hub.agent(slug: "pi"))
        #expect(after.tokenHash == AgentTokenFiles.hash(token))
        #expect(AgentScopes(csv: after.scopesRaw) == .standard)
    }

    @Test func writeAllIsEnforcedForThePiTokenInBothDirections() throws {
        let f = files()
        let (hub, store, d) = try rig(f)
        let token = try #require(AgentTokenFiles.generateToken())
        try f.write(token, slug: "pi")
        hub.adoptTokenFiles()
        let task = store.createNoUndo(title: "Owner's task")

        let denied = try update(d, task.id, as: try identity(hub, token: token))
        #expect(denied.isError && denied.code == "FORBIDDEN")
        #expect(store.task(task.id)?.title == "Owner's task")

        var s = AgentScopes(csv: try #require(hub.agent(slug: "pi")).scopesRaw)
        s.set.insert(.writeAll); hub.setScopes(s, slug: "pi")
        let allowed = try update(d, task.id, as: try identity(hub, token: token))
        #expect(!allowed.isError)
        #expect(store.task(task.id)?.title == "By pi")

        s.set.remove(.writeAll); hub.setScopes(s, slug: "pi")
        #expect(try update(d, task.id, as: try identity(hub, token: token)).code == "FORBIDDEN")
    }
}
#endif
