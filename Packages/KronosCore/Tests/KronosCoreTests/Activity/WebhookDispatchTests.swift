#if os(macOS)
import Testing
import Foundation
@testable import KronosCore

private final class FakeTransport: DeliveryTransport, @unchecked Sendable {
    var accept = true
    var sent: [(DeliveryMessage, DeliveryTarget, String?)] = []
    func send(_ message: DeliveryMessage, to target: DeliveryTarget, secret: String?) async -> Bool {
        sent.append((message, target, secret))
        return accept
    }
}

@MainActor
@Suite struct WebhookDispatchTests {

    private func rig() throws -> (AgentRig, AgentIdentity, FakeTransport, WebhookDispatcher) {
        let r = try AgentRig()
        let a = r.agent("relay", scopes: AgentScopes([.read, .propose, .writeOwn, .comment, .writeTrusted]))
        r.hub.setDeliveryTarget("https://relay.example.com/ingest", slug: "relay")
        r.hub.agent(slug: "relay")?.webhookSecretName = "agent_relay_hook"
        let t = FakeTransport()
        return (r, a, t, WebhookDispatcher(hub: r.hub, transport: t, secrets: { $0 == "agent_relay_hook" ? "whsec" : nil }))
    }

    @Test func aPendingEventIsDeliveredOnceWithTheSecretAndMarkedDelivered() async throws {
        let (r, a, transport, d) = try rig()
        let id = try r.taskID(r.call("create_task", ["title": "Ship it"], as: a))
        r.store.complete(id)
        r.hub.sync(store: r.store)
        let result = await d.run(store: r.store)
        #expect(result.delivered == 1 && result.retrying == 0 && result.dead == 0)
        #expect(transport.sent.count == 1)
        #expect(transport.sent[0].2 == "whsec")
        #expect(transport.sent[0].0.kind == ActivityVerb.completed)
        #expect(r.hub.rows().filter { $0.webhookStateRaw == 2 }.count == 1)
        let again = await d.run(store: r.store)
        #expect(again.delivered == 0 && transport.sent.count == 1, "a delivered event is never sent twice")
    }

    @Test func aFailedDeliveryWaitsForTheScheduleThenRetries() async throws {
        let (r, a, transport, d) = try rig()
        transport.accept = false
        r.hub.append(actor: "me", verb: ActivityVerb.completed, taskID: UUID(), agentID: a.agentID, payload: ["title": .string("X")])
        var out = await d.run(store: r.store)
        #expect(out.delivered == 0 && out.retrying == 1 && transport.sent.count == 1)
        out = await d.run(store: r.store)
        #expect(transport.sent.count == 1, "no second try inside the first minute")
        r.advance(61)
        transport.accept = true
        out = await d.run(store: r.store)
        #expect(out.delivered == 1 && transport.sent.count == 2)
    }

    @Test func anEventStillFailingAfterTwentyFourHoursIsDeadAndCounted() async throws {
        let (r, a, transport, d) = try rig()
        transport.accept = false
        r.hub.append(actor: "me", verb: ActivityVerb.completed, taskID: UUID(), agentID: a.agentID)
        _ = await d.run(store: r.store)
        r.advance(86_400)
        let out = await d.run(store: r.store)
        #expect(out.dead == 1)
        #expect(r.hub.undelivered(agentID: a.agentID) == (pending: 0, dead: 1))
        #expect(transport.sent.count == 1, "nothing is sent to a dead event")
    }

    @Test func switchingDeliveryOffStopsPendingEvents() async throws {
        let (r, a, transport, d) = try rig()
        r.hub.append(actor: "me", verb: ActivityVerb.completed, taskID: UUID(), agentID: a.agentID)
        r.hub.setDeliveryTarget(nil, slug: "relay")
        let out = await d.run(store: r.store)
        #expect(out.delivered == 0 && transport.sent.isEmpty)
        #expect(r.hub.undelivered(agentID: a.agentID).pending == 0)
    }

    @Test func thePayloadCarriesOnlyThatAgentsTaskAndTheMemoryBlock() throws {
        let (r, a, _, _) = try rig()
        let other = r.agent("codex")
        let mine = try r.taskID(r.call("create_task", ["title": "Mine to do"], as: a))
        let theirs = try r.taskID(r.call("create_task", ["title": "Secret of codex"], as: other))
        r.store.complete(mine); r.store.complete(theirs)
        r.hub.sync(store: r.store)
        let row = try #require(r.hub.rows().first { $0.verb == ActivityVerb.completed && $0.agentID == a.agentID })
        let json = try #require(JSONSerialization.jsonObject(with: WebhookDispatcher.payload(for: row, store: r.store)) as? [String: Any])
        #expect(json["title"] as? String == "Mine to do")
        #expect(json["taskID"] as? String == mine.uuidString)
        let text = String(decoding: WebhookDispatcher.payload(for: row, store: r.store), as: UTF8.self)
        #expect(!text.contains("Secret of codex") && !text.contains(theirs.uuidString))
        let memory = try #require(json["memory"] as? [String: Any])
        #expect((memory["markdown"] as? String)?.hasPrefix("---\nname: kronos-") == true)
    }
}

#endif
