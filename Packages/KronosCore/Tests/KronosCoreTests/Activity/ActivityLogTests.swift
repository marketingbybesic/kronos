import Testing
import Foundation
@testable import KronosCore

@MainActor
@Suite struct ActivityLogTests {

    private func completedEvent(_ rig: AgentRig, agent: AgentIdentity, taskID: UUID) {
        rig.hub.append(actor: "me", verb: ActivityVerb.completed, taskID: taskID, agentID: agent.agentID,
                       payload: ["title": .string("T")])
    }

    @Test func seqNumbersEventsOneUpFromZero() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        let rows = (0..<4).map { _ in rig.hub.append(actor: "me", verb: ActivityVerb.completed, taskID: UUID(), agentID: a.agentID) }
        #expect(rows.map(\.seq) == [1, 2, 3, 4])
    }

    @Test func anAgentHearsOnlyEventsAboutItsOwnTasks() throws {
        let rig = try AgentRig()
        let codex = rig.agent("codex"), relay = rig.agent("relay")
        completedEvent(rig, agent: codex, taskID: UUID())
        completedEvent(rig, agent: relay, taskID: UUID())
        completedEvent(rig, agent: codex, taskID: UUID())
        #expect(rig.hub.events(for: codex, since: 0).events.map(\.seq) == [1, 3])
        #expect(rig.hub.events(for: relay, since: 0).events.map(\.seq) == [2])
    }

    @Test func anAgentNeverHearsItsOwnWritesOrBookkeeping() throws {
        let rig = try AgentRig()
        let codex = rig.agent("codex")
        rig.hub.append(actor: codex.actor, verb: ActivityVerb.completed, taskID: UUID(), agentID: codex.agentID)
        rig.hub.append(actor: codex.actor, verb: ActivityVerb.created, taskID: UUID(), agentID: codex.agentID)
        rig.hub.append(actor: "system", verb: ActivityVerb.ack, agentID: codex.agentID, payload: ["upTo": .number(1)])
        #expect(rig.hub.events(for: codex, since: 0).events.isEmpty)
        // Another agent's comment on its task is heard.
        rig.hub.append(actor: "agent:relay", verb: ActivityVerb.commented, taskID: UUID(), agentID: codex.agentID)
        #expect(rig.hub.events(for: codex, since: 0).events.count == 1)
    }

    @Test func sinceLimitAndKindsNarrowTheFeedAndMoreSaysSo() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        for v in [ActivityVerb.completed, ActivityVerb.approved, ActivityVerb.completed, ActivityVerb.rejected, ActivityVerb.completed] {
            rig.hub.append(actor: "me", verb: v, taskID: UUID(), agentID: a.agentID)
        }
        #expect(rig.hub.events(for: a, since: 2).events.map(\.seq) == [3, 4, 5])
        let page = rig.hub.events(for: a, since: 0, limit: 2)
        #expect(page.events.map(\.seq) == [1, 2] && page.more)
        #expect(rig.hub.events(for: a, since: 0, limit: 5).more == false)
        #expect(rig.hub.events(for: a, since: 0, kinds: [ActivityVerb.completed]).events.map(\.seq) == [1, 3, 5])
        // A kind outside the delivered set never matches.
        #expect(rig.hub.events(for: a, since: 0, kinds: [ActivityVerb.created]).events.isEmpty)
    }

    @Test func theAckCursorMovesForwardOnly() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        #expect(rig.hub.ackedCursor(agentID: a.agentID) == 0)
        #expect(rig.hub.ack(agentID: a.agentID, upTo: 7) == 7)
        #expect(rig.hub.ack(agentID: a.agentID, upTo: 3) == 7)
        #expect(rig.hub.ackedCursor(agentID: a.agentID) == 7)
        let b = rig.agent("relay")
        #expect(rig.hub.ackedCursor(agentID: b.agentID) == 0, "cursors are per agent")
    }

    @Test func rowsOlderThanSixtyDaysAreDroppedAndTheNewestAckIsKept() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        rig.hub.append(actor: "me", verb: ActivityVerb.completed, taskID: UUID(), agentID: a.agentID)   // seq 1
        rig.hub.ack(agentID: a.agentID, upTo: 1)                                                           // seq 2
        rig.advance(59 * 86_400)
        rig.hub.append(actor: "me", verb: ActivityVerb.completed, taskID: UUID(), agentID: a.agentID)   // seq 3, 59 days later
        #expect(rig.hub.prune() == 0, "nothing is 60 days old yet")
        rig.advance(2 * 86_400)                                                                            // rows 1-2 are 61 days old
        #expect(rig.hub.prune() == 1, "the old event goes, the newest ack stays")
        #expect(rig.hub.ackedCursor(agentID: a.agentID) == 1)
        #expect(rig.hub.rows().map(\.seq) == [2, 3])
    }

    @Test func createsTodayAndWriteCountsComeFromTheLog() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        for _ in 0..<3 { rig.hub.append(actor: a.actor, verb: ActivityVerb.created, taskID: UUID(), agentID: a.agentID) }
        rig.hub.append(actor: "me", verb: ActivityVerb.completed, taskID: UUID(), agentID: a.agentID)
        #expect(rig.hub.createsToday(agent: a) == 3)
        #expect(rig.hub.writeCount(agentID: a.agentID, days: 7) == 3, "the owner's event is not an agent write")
        rig.advance(8 * 86_400)
        #expect(rig.hub.writeCount(agentID: a.agentID, days: 7) == 0)
        #expect(rig.hub.createsToday(agent: a) == 0)
    }

    @Test func aDeliveryTargetMarksNewEventsForTheWebhook() throws {
        let rig = try AgentRig()
        let a = rig.agent("relay")
        let before = rig.hub.append(actor: "me", verb: ActivityVerb.completed, taskID: UUID(), agentID: a.agentID)
        #expect(before.webhookStateRaw == 0)
        rig.hub.setDeliveryTarget("https://example.com/hook", slug: "relay")
        let after = rig.hub.append(actor: "me", verb: ActivityVerb.completed, taskID: UUID(), agentID: a.agentID)
        #expect(after.webhookStateRaw == 1)
        let audit = rig.hub.append(actor: a.actor, verb: ActivityVerb.created, taskID: UUID(), agentID: a.agentID)
        #expect(audit.webhookStateRaw == 0, "an agent's own write is never delivered back")
    }
}
