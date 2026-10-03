import Testing
import Foundation
@testable import KronosCore

@MainActor
@Suite struct MCPLongPollTests {

    private func rpc(_ args: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                                    "params": ["name": "events_poll", "arguments": args]])
    }

    private func events(_ reply: MCPDispatcher.Reply) throws -> Int {
        let data = try #require(reply.body)
        let top = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let res = try #require(top["result"] as? [String: Any])
        return ((res["structuredContent"] as? [String: Any])?["events"] as? [Any])?.count ?? -1
    }

    private func trusted(_ rig: AgentRig) -> AgentIdentity {
        rig.agent("codex", scopes: AgentScopes([.read, .propose, .writeOwn, .comment, .writeTrusted]))
    }

    /// A clock the tests drive: `sleep` advances it instead of waiting.
    final class FakeClock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_000)
        var sleeps: [TimeInterval] = []
        var onSleep: (() -> Void)?
        func sleep(_ s: TimeInterval) async { sleeps.append(s); now = now.addingTimeInterval(s); onSleep?(); await Task.yield() }
    }

    @Test func aPollWithNoEventsIsHeldToTheDeadlineThenReturnsEmpty() async throws {
        let rig = try AgentRig()
        let a = trusted(rig)
        let clock = FakeClock()
        let reply = await rig.dispatcher.handleBodyHolding(try rpc(["waitSeconds": 50]), agent: a,
                                                           sleep: { await clock.sleep($0) }, now: { clock.now })
        #expect(try events(reply) == 0)
        #expect(clock.sleeps.reduce(0, +) == 50, "held for the whole 50 s")
        #expect(clock.sleeps.allSatisfy { $0 <= MCPDispatcher.longPollInterval })
    }

    @Test func waitSecondsIsCappedAtFiftyFive() async throws {
        let rig = try AgentRig()
        let a = trusted(rig)
        let clock = FakeClock()
        _ = await rig.dispatcher.handleBodyHolding(try rpc(["waitSeconds": 55]), agent: a, sleep: { await clock.sleep($0) }, now: { clock.now })
        #expect(clock.sleeps.reduce(0, +) == 55)
        #expect(MCPDispatcher.maxWaitSeconds == 55)
        let direct = rig.dispatcher.longPollSeconds(in: try rpc(["waitSeconds": 9999]))
        #expect(direct == 55)
    }

    @Test func anEventThatAppearsWhileWaitingEndsTheWaitEarly() async throws {
        let rig = try AgentRig()
        let a = trusted(rig)
        let id = try rig.taskID(rig.call("create_task", ["title": "Reply"], as: a))
        let clock = FakeClock()
        clock.onSleep = { if clock.sleeps.count == 3 { rig.store.complete(id) } }   // the person finishes it during the wait
        let reply = await rig.dispatcher.handleBodyHolding(try rpc(["waitSeconds": 50]), agent: a, sleep: { await clock.sleep($0) }, now: { clock.now })
        #expect(try events(reply) == 1)
        #expect(clock.sleeps.count == 3, "returned within a look of the change, not at 50 s")
        #expect(clock.sleeps.reduce(0, +) < 10)
    }

    @Test func anExistingEventReturnsAtOnceWithoutWaiting() async throws {
        let rig = try AgentRig()
        let a = trusted(rig)
        let id = try rig.taskID(rig.call("create_task", ["title": "Reply"], as: a))
        rig.store.complete(id)
        let clock = FakeClock()
        let reply = await rig.dispatcher.handleBodyHolding(try rpc(["waitSeconds": 50]), agent: a, sleep: { await clock.sleep($0) }, now: { clock.now })
        #expect(try events(reply) == 1 && clock.sleeps.isEmpty)
    }

    @Test func aHeldPollCountsOnceAgainstTheRateLimit() async throws {
        let rig = try AgentRig()
        let a = trusted(rig)
        for _ in 1...58 { _ = try rig.call("whoami", as: a) }          // 58 of 60 used
        let clock = FakeClock()
        let reply = await rig.dispatcher.handleBodyHolding(try rpc(["waitSeconds": 30]), agent: a, sleep: { await clock.sleep($0) }, now: { clock.now })
        #expect(try events(reply) == 0 && clock.sleeps.count >= 30, "thirty looks, one call")
        #expect(try !rig.call("whoami", as: a).isError, "59 calls used so far: one more is allowed")
        #expect(try rig.call("whoami", as: a).code == "RATE_LIMITED", "the 61st is not")
    }

    @Test func aRefusedPollEndsTheWaitAtOnce() async throws {
        let rig = try AgentRig()
        let readless = rig.agent("mute", scopes: AgentScopes([]))
        let clock = FakeClock()
        let reply = await rig.dispatcher.handleBodyHolding(try rpc(["waitSeconds": 50]), agent: readless, sleep: { await clock.sleep($0) }, now: { clock.now })
        #expect(clock.sleeps.isEmpty)
        let data = try #require(reply.body)
        let top = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(((top["result"] as? [String: Any])?["structuredContent"] as? [String: Any])?["error"] as? String == "FORBIDDEN")
    }

    @Test func aRequestWithoutWaitIsAnsweredSynchronously() async throws {
        let rig = try AgentRig()
        let a = trusted(rig)
        let clock = FakeClock()
        let reply = await rig.dispatcher.handleBodyHolding(try rpc([:]), agent: a, sleep: { await clock.sleep($0) }, now: { clock.now })
        #expect(try events(reply) == 0 && clock.sleeps.isEmpty)
        #expect(rig.dispatcher.longPollSeconds(in: try rpc(["waitSeconds": 0])) == nil)
    }

    // The point of item: while a long poll waits, the main actor is free to do other work.

    /// While a long poll waits, the main actor is free: other main-actor work interleaves with the
    /// poll's looks instead of queueing behind a blocked thread. Counted in turns, not seconds, so
    /// other tests running at the same time cannot make it flaky.
    @Test func theMainActorKeepsRunningWhileAPollIsHeld() async throws {
        let rig = try AgentRig()
        let a = trusted(rig)
        let clock = FakeClock()
        var finished = false
        let body = try rpc(["waitSeconds": 50])
        let poll = Task { @MainActor () -> MCPDispatcher.Reply in
            let reply = await rig.dispatcher.handleBodyHolding(body, agent: a,
                                                               sleep: { s in clock.now = clock.now.addingTimeInterval(s); await Task.yield() },
                                                               now: { clock.now })
            finished = true
            return reply
        }
        var ticks = 0
        while !finished && ticks < 10_000 {
            ticks += 1
            await Task.yield()
        }
        // 50 s at one look a second is 50 suspensions; each lets this loop run. A blocked main thread gives 0..1.
        #expect(ticks >= 25, "main-actor work ran \(ticks) turns while the poll was held")
        let reply = try await poll.value
        #expect(try events(reply) == 0)
    }

    @Test func aWriteOnTheMainActorDuringTheWaitIsSeenByThePoll() async throws {
        let rig = try AgentRig()
        let a = trusted(rig)
        let id = try rig.taskID(rig.call("create_task", ["title": "During the wait"], as: a))
        let clock = FakeClock()
        var looks = 0
        var finished = false
        let body = try rpc(["waitSeconds": 50])
        let poll = Task { @MainActor () -> MCPDispatcher.Reply in
            let reply = await rig.dispatcher.handleBodyHolding(body, agent: a,
                                                               sleep: { s in looks += 1; clock.now = clock.now.addingTimeInterval(s); await Task.yield() },
                                                               now: { clock.now })
            finished = true
            return reply
        }
        var ticks = 0
        while !finished && ticks < 10_000 {
            ticks += 1
            if ticks == 10 { rig.store.complete(id) }     // the person finishes the task from the main actor
            await Task.yield()
        }
        let reply = try await poll.value
        #expect(try events(reply) == 1)
        #expect(looks < 50, "returned on the event after \(looks) looks, not at the 50 s deadline")
    }
}
