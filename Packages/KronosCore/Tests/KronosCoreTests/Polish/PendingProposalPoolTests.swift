import Testing
import Foundation
@testable import KronosCore

/// Pick one never offers an agent proposal that waits for review (reviewRaw 1), at any energy,
/// while the same task in every other review state is offered. Hand-written table.
@MainActor
@Suite struct PendingProposalPoolTests {

    private let engine = RankingEngine()
    private let today = Day.from(Date(timeIntervalSince1970: 1_790_000_000))

    /// review state -> may Pick one offer it
    private let table: [(review: Int, offered: Bool)] = [
        (0, true),    // an ordinary task
        (1, false),   // pending proposal: hidden until decided
        (2, true),    // approved proposal: an ordinary task now
        (4, true),    // agent says done, awaiting the person's check, still open
    ]

    @Test(arguments: [KEnergyLevel.low, .mid, .high])
    func pendingProposalsAreNeverCandidates(energy: KEnergyLevel) throws {
        let store = try TaskStore(inMemory: true)
        var ids: [Int: UUID] = [:]
        for row in table {
            let t = store.create(title: "review \(row.review)")
            store.update(t.id) {
                $0.reviewRaw = row.review
                $0.depthRaw = KDepth.shallow.rawValue
                $0.estimateMinutes = 10
                $0.priorityRaw = KPriority.urgent.rawValue
            }
            ids[row.review] = t.id
        }
        let picked = Set(engine.candidates(energy: energy, count: 10, maxDeep: true, today: today,
                                           tasks: store.allTasks()).map(\.taskID))
        for row in table {
            let id = try #require(ids[row.review])
            #expect(picked.contains(id) == row.offered, "review \(row.review) at \(energy)")
        }
    }

    @Test func aPendingProposalIsSkippedEvenWithTheDreadServingPath() throws {
        let store = try TaskStore(inMemory: true)
        let pending = store.create(title: "Agent proposal")
        store.update(pending.id) { $0.reviewRaw = 1; $0.dread = true; $0.priorityRaw = KPriority.urgent.rawValue }
        let normal = store.create(title: "Owner task")
        store.update(normal.id) { $0.priorityRaw = KPriority.low.rawValue }
        let picks = engine.candidates(energy: .high, count: 5, maxDeep: true, today: today,
                                      tasks: store.allTasks(), dreadServing: DreadServing())
        #expect(picks.map(\.taskID) == [normal.id])
    }

    @Test func aTaskWaitingOnlyOnAPendingProposalIsStillBlockedByIt() throws {
        // The proposal leaves the pool, not the lookup: what waits on it stays blocked.
        let store = try TaskStore(inMemory: true)
        let pending = store.create(title: "Agent proposal")
        store.update(pending.id) { $0.reviewRaw = 1 }
        let waiting = store.create(title: "Waits on the proposal")
        #expect(store.setWaitsOn(waiting.id, [pending.id]))
        let picks = engine.candidates(energy: .high, count: 5, maxDeep: true, today: today, tasks: store.allTasks())
        #expect(picks.isEmpty)
    }
}
