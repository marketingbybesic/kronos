#if os(macOS)
import Testing
import Foundation
@testable import KronosCore

/// `AgentTeamSignals` (round 2 #6/#8/#9): pure functions over activity rows already fetched by
/// the caller, plus the two `AgentHub` reads (`rows(from:)`, `latestSeq`) that feed them in the
/// app. Rows here are built directly with `AgentHub.append`, not through the dispatcher, so each
/// test controls exactly the actor/verb/payload shape it is checking.
@MainActor
@Suite struct AgentTeamSignalsTests {

    // MARK: awaySummary

    @Test func awaySummaryCountsAgentFinishedAndProposedRowsOnly() throws {
        let rig = try AgentRig()
        func row(_ actor: String, _ verb: String, _ payload: [String: AgentJSON]) {
            rig.hub.append(actor: actor, verb: verb, taskID: UUID(), payload: payload)
        }
        row("agent:codex", ActivityVerb.doneByAgent, ["title": .string("A")])
        row("agent:codex", ActivityVerb.doneByAgent, ["title": .string("B"), "auto": .bool(true)])
        row("agent:codex", ActivityVerb.created, ["title": .string("C"), "review": .number(1)])
        row("agent:codex", ActivityVerb.created, ["title": .string("D"), "review": .number(0)])
        row("me", ActivityVerb.doneByAgent, ["title": .string("owner done")])
        row("me", ActivityVerb.created, ["title": .string("owner created"), "review": .number(1)])
        row("system", ActivityVerb.doneByAgent, ["title": .string("sys done")])
        row("system", ActivityVerb.created, ["title": .string("sys created"), "review": .number(1)])

        let summary = AgentTeamSignals.awaySummary(rig.hub.rows())
        #expect(summary.finished == 2, "only the two agent-authored doneByAgent rows count")
        #expect(summary.proposed == 1, "only the one agent-authored pending created row counts")
    }

    @Test func isEmptyReflectsBothCountsBeingZero() {
        #expect(AgentAwaySummary(finished: 0, proposed: 0).isEmpty)
        #expect(!AgentAwaySummary(finished: 1, proposed: 0).isEmpty)
        #expect(!AgentAwaySummary(finished: 0, proposed: 1).isEmpty)
    }

    // MARK: workClaims

    @Test func workClaimsSetByAgentInProgressRow() throws {
        let rig = try AgentRig()
        let taskID = UUID()
        let at = rig.clock
        rig.hub.append(actor: "agent:codex", verb: ActivityVerb.updated, taskID: taskID,
                       payload: ["after": .object(["status": .number(Double(KStatus.inProgress.rawValue))])])
        let claims = AgentTeamSignals.workClaims(rig.hub.rows())
        #expect(claims[taskID] == AgentClaim(slug: "codex", at: at))
    }

    @Test func workClaimsClearedWhenStatusLeavesInProgress() throws {
        let rig = try AgentRig()
        let todoTask = UUID(), doneTask = UUID()
        for taskID in [todoTask, doneTask] {
            rig.hub.append(actor: "agent:codex", verb: ActivityVerb.updated, taskID: taskID,
                           payload: ["after": .object(["status": .number(Double(KStatus.inProgress.rawValue))])])
        }
        rig.advance(60)
        rig.hub.append(actor: "agent:codex", verb: ActivityVerb.updated, taskID: todoTask,
                       payload: ["after": .object(["status": .number(Double(KStatus.todo.rawValue))])])
        rig.hub.append(actor: "agent:codex", verb: ActivityVerb.updated, taskID: doneTask,
                       payload: ["after": .object(["status": .number(Double(KStatus.done.rawValue))])])
        let claims = AgentTeamSignals.workClaims(rig.hub.rows())
        #expect(claims[todoTask] == nil && claims[doneTask] == nil)
    }

    @Test func workClaimsIgnoresAnOwnerActorInProgressRow() throws {
        let rig = try AgentRig()
        let taskID = UUID()
        rig.hub.append(actor: "me", verb: ActivityVerb.updated, taskID: taskID,
                       payload: ["after": .object(["status": .number(Double(KStatus.inProgress.rawValue))])])
        let claims = AgentTeamSignals.workClaims(rig.hub.rows())
        #expect(claims[taskID] == nil, "an owner move to in-progress is not a working-status claim")
    }

    // MARK: notifiable

    @Test func notifiableExcludesAutoApprovedCompletions() throws {
        let rig = try AgentRig()
        rig.hub.append(actor: "agent:codex", verb: ActivityVerb.doneByAgent, taskID: UUID(), payload: ["title": .string("no key")])
        rig.hub.append(actor: "agent:codex", verb: ActivityVerb.doneByAgent, taskID: UUID(), payload: ["title": .string("false"), "auto": .bool(false)])
        rig.hub.append(actor: "agent:codex", verb: ActivityVerb.doneByAgent, taskID: UUID(), payload: ["title": .string("true"), "auto": .bool(true)])
        let notifiable = AgentTeamSignals.notifiable(rig.hub.rows())
        #expect(notifiable.count == 2)
        #expect(notifiable.allSatisfy { AgentHub.payload($0)["auto"]?.bool != true })
    }

    @Test func notifiableIgnoresVerbsThatAreNotDoneByAgent() throws {
        let rig = try AgentRig()
        rig.hub.append(actor: "agent:codex", verb: ActivityVerb.created, taskID: UUID(), payload: ["review": .number(1)])
        rig.hub.append(actor: "agent:codex", verb: ActivityVerb.updated, taskID: UUID(),
                       payload: ["after": .object(["status": .number(Double(KStatus.inProgress.rawValue))])])
        #expect(AgentTeamSignals.notifiable(rig.hub.rows()).isEmpty)
    }

    // MARK: AgentHub.rows(from:) / latestSeq

    @Test func rowsFromReturnsOnlyRowsAtOrAfterTheDate() throws {
        let rig = try AgentRig()
        rig.hub.append(actor: "agent:codex", verb: ActivityVerb.created, taskID: UUID(), payload: ["title": .string("early")])
        rig.advance(3_600)
        let cutoff = rig.clock
        rig.hub.append(actor: "agent:codex", verb: ActivityVerb.created, taskID: UUID(), payload: ["title": .string("at cutoff")])
        rig.advance(3_600)
        rig.hub.append(actor: "agent:codex", verb: ActivityVerb.created, taskID: UUID(), payload: ["title": .string("late")])

        let fromCutoff = rig.hub.rows(from: cutoff)
        #expect(fromCutoff.count == 2)
        #expect(fromCutoff.allSatisfy { $0.at >= cutoff })
        #expect(!fromCutoff.contains { AgentHub.payload($0)["title"]?.string == "early" })
    }

    @Test func latestSeqMatchesTheLastAppendedRow() throws {
        let rig = try AgentRig()
        rig.hub.append(actor: "agent:codex", verb: ActivityVerb.created, taskID: UUID())
        rig.hub.append(actor: "agent:codex", verb: ActivityVerb.created, taskID: UUID())
        let last = rig.hub.append(actor: "agent:codex", verb: ActivityVerb.created, taskID: UUID())
        #expect(rig.hub.latestSeq == last.seq)
    }
}
#endif
