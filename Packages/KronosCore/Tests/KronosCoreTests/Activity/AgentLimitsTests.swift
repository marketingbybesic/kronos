#if os(macOS)
import Testing
import Foundation
@testable import KronosCore

@MainActor
@Suite struct AgentLimitsTests {

    @Test func theBucketAllowsTheCapacityThenRefusesWithARetryTime() {
        var t = Date(timeIntervalSince1970: 0)
        let limiter = AgentLimiter(now: { t })
        for i in 1...60 { #expect(limiter.consume(slug: "codex", perMinute: 60).allowed, "call \(i)") }
        let refused = limiter.consume(slug: "codex", perMinute: 60)
        #expect(!refused.allowed && refused.retryAfter == 1, "60 a minute = one free per second")
        t = t.addingTimeInterval(1)
        #expect(limiter.consume(slug: "codex", perMinute: 60).allowed)
        #expect(!limiter.consume(slug: "codex", perMinute: 60).allowed)
        t = t.addingTimeInterval(120)
        for _ in 1...60 { #expect(limiter.consume(slug: "codex", perMinute: 60).allowed) }
        #expect(!limiter.consume(slug: "codex", perMinute: 60).allowed, "refill is capped at the capacity")
    }

    @Test func eachAgentHasItsOwnBucket() {
        let limiter = AgentLimiter(now: { Date(timeIntervalSince1970: 0) })
        for _ in 1...3 { _ = limiter.consume(slug: "a", perMinute: 3) }
        #expect(!limiter.consume(slug: "a", perMinute: 3).allowed)
        #expect(limiter.consume(slug: "b", perMinute: 3).allowed)
    }

    @Test func aSlowerLimitMeansALongerWait() {
        let limiter = AgentLimiter(now: { Date(timeIntervalSince1970: 0) })
        for _ in 1...6 { _ = limiter.consume(slug: "a", perMinute: 6) }
        #expect(limiter.consume(slug: "a", perMinute: 6).retryAfter == 10, "6 a minute = one every 10 s")
    }

    // MARK: through the dispatcher

    @Test func theSixtyFirstCallInAMinuteIsRateLimited() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        for _ in 1...60 { #expect(try !rig.call("whoami", as: a).isError) }
        let r = try rig.call("whoami", as: a)
        #expect(r.isError && r.code == "RATE_LIMITED")
        rig.advance(60)
        #expect(try !rig.call("whoami", as: a).isError, "a minute later the bucket is full again")
    }

    @Test func theFortyFirstTaskOfADayIsRefusedAndTomorrowResets() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex", scopes: AgentScopes([.read, .propose, .writeOwn, .writeTrusted]))
        for i in 1...40 {
            #expect(try !rig.call("create_task", ["title": "T\(i)"], as: a).isError, "task \(i)")
            rig.advance(2)   // keep under the per-minute bucket
        }
        let r = try rig.call("create_task", ["title": "T41"], as: a)
        #expect(r.isError && r.code == "RATE_LIMITED" && r.message.contains("daily"))
        rig.advance(86_400)
        #expect(try !rig.call("create_task", ["title": "Next day"], as: a).isError)
    }

    @Test func aBatchThatWouldPassTheDailyCapIsRefusedWhole() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        rig.hub.agent(slug: "codex")?.dailyCreateCap = 3
        let a3 = try #require(rig.hub.identity(slug: "codex"))
        let tasks = (1...4).map { ["title": "T\($0)"] }
        let r = try rig.call("propose_tasks", ["title": "Plan", "tasks": tasks], as: a3)
        #expect(r.code == "RATE_LIMITED")
        #expect(rig.store.allTasks().isEmpty, "nothing was created")
        _ = a
    }

    @Test func sixteenthProposalIsRefusedWithReviewBacklogAndTheOwnersWords() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        for i in 1...15 {
            #expect(try !rig.call("create_task", ["title": "P\(i)"], as: a).isError, "proposal \(i)")
            rig.advance(2)
        }
        let r = try rig.call("create_task", ["title": "P16"], as: a)
        #expect(r.isError && r.code == "REVIEW_BACKLOG")
        #expect(r.message == "Alex has 15 unreviewed proposals (limit 15); wait for events before proposing more")
        // Approving one frees a slot.
        let first = try #require(rig.store.allTasks().first { $0.reviewRaw == 1 })
        #expect(AgentReview.approve(first.id, store: rig.store))
        #expect(try !rig.call("create_task", ["title": "P16 again"], as: a).isError)
    }

    @Test func aBatchCountsAsOneProposalForTheBacklog() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        let tasks = (1...5).map { ["title": "T\($0)"] }
        _ = try rig.call("propose_tasks", ["title": "Plan", "tasks": tasks], as: a)
        #expect(rig.hub.pendingProposals(agentID: a.agentID, store: rig.store) == 1)
    }

    @Test func aTrustedAgentIsNotHeldByTheReviewBacklog() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex", scopes: AgentScopes([.read, .propose, .writeOwn, .writeTrusted]))
        rig.hub.agent(slug: "codex")?.maxPendingProposals = 1
        let a1 = try #require(rig.hub.identity(slug: "codex"))
        _ = try rig.call("propose_tasks", ["title": "P", "tasks": [["title": "x"]]], as: a1)
        #expect(try !rig.call("create_task", ["title": "trusted create"], as: a1).isError,
                "a trusted create is not a proposal, so the backlog does not apply")
        _ = a
    }
}

#endif
