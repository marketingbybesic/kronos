import Testing
import Foundation
@testable import KronosCore

@MainActor
struct RankingEngineTests {
    let engine = RankingEngine()
    let today = Day.today()

    private func makeStore() throws -> TaskStore {
        try TaskStore(inMemory: true)
    }

    @Test func lowEnergyPrefersShallowQuickNonDread() throws {
        let store = try makeStore()
        let quick = store.create(title: "quick")
        store.update(quick.id) { $0.depthRaw = KDepth.shallow.rawValue; $0.estimateMinutes = 10 }
        let dreaded = store.create(title: "dreaded")
        store.update(dreaded.id) { $0.depthRaw = KDepth.shallow.rawValue; $0.estimateMinutes = 5; $0.dread = true }
        let deep = store.create(title: "deep")
        store.update(deep.id) { $0.depthRaw = KDepth.deep.rawValue }

        let c = engine.candidates(energy: .low, count: 5, maxDeep: false,
                                  today: today, tasks: store.allTasks())
        #expect(c.first?.taskID == quick.id)
        #expect(!c.contains { $0.taskID == deep.id })
    }

    @Test func midEnergyPriorityFirstDreadTiebreak() throws {
        let store = try makeStore()
        let low = store.create(title: "low")
        store.update(low.id) { $0.priorityRaw = KPriority.low.rawValue; $0.dread = false }
        let highDread = store.create(title: "highdread")
        store.update(highDread.id) { $0.priorityRaw = KPriority.high.rawValue; $0.dread = true }

        let c = engine.candidates(energy: .mid, count: 2, maxDeep: false,
                                  today: today, tasks: store.allTasks())
        #expect(c.first?.taskID == highDread.id) // priority dominates dread
    }

    @Test func highEnergyAllowsDeep() throws {
        let store = try makeStore()
        let deep = store.create(title: "deep")
        store.update(deep.id) { $0.depthRaw = KDepth.deep.rawValue; $0.priorityRaw = KPriority.urgent.rawValue }

        let c = engine.candidates(energy: .high, count: 3, maxDeep: true,
                                  today: today, tasks: store.allTasks())
        #expect(c.first?.taskID == deep.id)
    }

    @Test func excludedWhenArchivedOrClosed() throws {
        let store = try makeStore()
        let done = store.create(title: "done")
        store.complete(done.id)
        let waiting = store.create(title: "wait")
        store.setStatus(waiting.id, .waiting)

        let c = engine.candidates(energy: .mid, count: 5, maxDeep: false,
                                  today: today, tasks: store.allTasks())
        #expect(!c.contains { $0.taskID == done.id })
        #expect(!c.contains { $0.taskID == waiting.id })
    }
}