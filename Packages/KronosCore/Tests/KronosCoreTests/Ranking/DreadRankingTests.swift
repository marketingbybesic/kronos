import Testing
import Foundation
@testable import KronosCore

/// Dread never demotes a task; one dread task is served per day at Mid/High, never twice in a row.
/// Expected orders are written by hand from the rule, not read back from the engine.
@MainActor
struct DreadRankingTests {
    let engine = RankingEngine()
    let today = Day.today()

    private func makeStore() throws -> TaskStore { try TaskStore(inMemory: true) }

    @discardableResult
    private func add(_ store: TaskStore, _ title: String, priority: KPriority = .none, dread: Bool = false,
                     shallow: Bool = false) -> KTask {
        let t = store.create(title: title)
        store.update(t.id) {
            $0.priorityRaw = priority.rawValue
            $0.dread = dread
            if shallow { $0.depthRaw = KDepth.shallow.rawValue; $0.estimateMinutes = 5 }
        }
        return t
    }

    private func titles(_ c: [Candidate], _ store: TaskStore) -> [String] {
        c.map { id in store.allTasks().first { $0.id == id.taskID }?.title ?? "?" }
    }

    @Test func midEnergyDreadHasNoPenalty() throws {
        let store = try makeStore()
        add(store, "dreaded", priority: .medium, dread: true)   // created first = manual order first
        add(store, "plain", priority: .medium)
        let c = engine.candidates(energy: .mid, count: 5, maxDeep: false, today: today, tasks: store.allTasks())
        #expect(titles(c, store) == ["dreaded", "plain"])
        #expect(c.map(\.reason) == ["Next by priority", "Next by priority"])
        // positive control: the same pool with the flags swapped flips nothing but the flag.
        let store2 = try makeStore()
        add(store2, "plain", priority: .medium)
        add(store2, "dreaded", priority: .medium, dread: true)
        let c2 = engine.candidates(energy: .mid, count: 5, maxDeep: false, today: today, tasks: store2.allTasks())
        #expect(titles(c2, store2) == ["plain", "dreaded"])
    }

    @Test func lowEnergyDreadHasNoPenaltyAndNoGuiltCopy() throws {
        let store = try makeStore()
        add(store, "dreaded", dread: true, shallow: true)
        add(store, "plain", shallow: true)
        let c = engine.candidates(energy: .low, count: 5, maxDeep: false, today: today, tasks: store.allTasks())
        #expect(titles(c, store) == ["dreaded", "plain"])
        #expect(c.map(\.reason) == ["Shallow and quick", "Shallow and quick"])
        #expect(!c.contains { $0.reason.lowercased().contains("avoid") })
    }

    @Test func highEnergyDreadFollowsPriorityAndDue() throws {
        let store = try makeStore()
        add(store, "plain-urgent", priority: .urgent)
        add(store, "dread-low", priority: .low, dread: true)
        let c = engine.candidates(energy: .high, count: 5, maxDeep: true, today: today, tasks: store.allTasks())
        #expect(titles(c, store) == ["plain-urgent", "dread-low"])
    }

    @Test func noServingStateLeavesOrderUntouched() throws {
        let store = try makeStore()
        add(store, "plain-high", priority: .high)
        add(store, "dread-low", priority: .low, dread: true)
        let c = engine.candidates(energy: .mid, count: 5, maxDeep: false, today: today, tasks: store.allTasks(),
                                  dreadServing: nil)
        #expect(titles(c, store) == ["plain-high", "dread-low"])
    }

    @Test func servesOneDreadFirstWhenAllowedAtMidAndHigh() throws {
        let store = try makeStore()
        add(store, "plain-high", priority: .high)
        add(store, "dread-low", priority: .low, dread: true)
        for energy in [KEnergyLevel.mid, .high] {
            let c = engine.candidates(energy: energy, count: 5, maxDeep: true, today: today, tasks: store.allTasks(),
                                      dreadServing: DreadServing())
            #expect(titles(c, store) == ["dread-low", "plain-high"], "energy \(energy)")
            #expect(c.first?.isDread == true)
            #expect(c.first?.reason != nil && !(c.first!.reason.lowercased().contains("avoid")))
        }
    }

    @Test func lowEnergyNeverPromotesDread() throws {
        let store = try makeStore()
        add(store, "plain", shallow: true)
        add(store, "dreaded", dread: true, shallow: true)
        let c = engine.candidates(energy: .low, count: 5, maxDeep: false, today: today, tasks: store.allTasks(),
                                  dreadServing: DreadServing())
        #expect(titles(c, store) == ["plain", "dreaded"])
    }

    @Test func notServedAgainTodayOrTwiceInARow() throws {
        let store = try makeStore()
        add(store, "dread-high", priority: .high, dread: true)
        add(store, "plain-low", priority: .low)
        let tasks = store.allTasks()
        // Already served today: the dread task would lead by priority, but may not.
        let served = engine.candidates(energy: .mid, count: 5, maxDeep: false, today: today, tasks: tasks,
                                       dreadServing: DreadServing(servedDay: today, lastPickWasDread: false))
        #expect(titles(served, store) == ["plain-low", "dread-high"])
        // Last pick was a dread task (served yesterday): not twice in a row either.
        let again = engine.candidates(energy: .mid, count: 5, maxDeep: false, today: today, tasks: tasks,
                                      dreadServing: DreadServing(servedDay: today - 1, lastPickWasDread: true))
        #expect(titles(again, store) == ["plain-low", "dread-high"])
        // Served yesterday and the last pick was not dread: allowed, and it leads.
        let fresh = engine.candidates(energy: .mid, count: 5, maxDeep: false, today: today, tasks: tasks,
                                      dreadServing: DreadServing(servedDay: today - 1, lastPickWasDread: false))
        #expect(titles(fresh, store) == ["dread-high", "plain-low"])
    }

    @Test func onlyDreadTasksLeftStillReturnsThem() throws {
        let store = try makeStore()
        add(store, "d1", dread: true)
        add(store, "d2", dread: true)
        let c = engine.candidates(energy: .mid, count: 5, maxDeep: false, today: today, tasks: store.allTasks(),
                                  dreadServing: DreadServing(servedDay: today, lastPickWasDread: true))
        #expect(titles(c, store) == ["d1", "d2"])   // never an empty card because of the cap
    }

    @Test func recordingTracksTheShownPick() throws {
        let store = try makeStore()
        let d = add(store, "d", dread: true)
        let p = add(store, "p")
        let dc = Candidate(taskID: d.id, reason: "", isDread: true)
        let pc = Candidate(taskID: p.id, reason: "", isDread: false)
        #expect(DreadServing().recording(dc, today: 10) == DreadServing(servedDay: 10, lastPickWasDread: true))
        #expect(DreadServing(servedDay: 10, lastPickWasDread: true).recording(pc, today: 10)
                == DreadServing(servedDay: 10, lastPickWasDread: false))
        #expect(DreadServing(servedDay: 9, lastPickWasDread: false).recording(nil, today: 10)
                == DreadServing(servedDay: 9, lastPickWasDread: false))
    }

    /// Six picks in one day from three dread and three plain tasks, each shown pick removed from
    /// the pool: one dread pick while plain tasks remain. The next day allows one more.
    @Test func atMostOneDreadPickPerDaySimulation() throws {
        let store = try makeStore()
        for i in 1...3 { add(store, "dread\(i)", priority: .medium, dread: true) }
        for i in 1...3 { add(store, "plain\(i)", priority: .medium) }
        var pool = store.allTasks()
        var serving = DreadServing()
        var picks: [String] = []
        for _ in 0..<6 {
            let c = engine.candidates(energy: .mid, count: 1, maxDeep: false, today: today, tasks: pool,
                                      dreadServing: serving)
            guard let pick = c.first else { break }
            picks.append(titles([pick], store)[0])
            serving = serving.recording(pick, today: today)
            pool.removeAll { $0.id == pick.taskID }
        }
        #expect(picks == ["dread1", "plain1", "plain2", "plain3", "dread2", "dread3"])
        // While a plain task is left (picks 0-3) there is exactly one dread pick, the first.
        // Only once none is left (picks 4-5) does the cap yield, so the card is never empty.
        let dreadPositions = picks.indices.filter { picks[$0].hasPrefix("dread") }
        #expect(dreadPositions == [0, 4, 5])
        #expect(dreadPositions.filter { $0 < 4 }.count == 1)

        // Next day, plain tasks still around: one dread leads again.
        let store2 = try makeStore()
        add(store2, "dreadA", priority: .medium, dread: true)
        add(store2, "plainA", priority: .medium)
        let next = engine.candidates(energy: .mid, count: 1, maxDeep: false, today: today + 1, tasks: store2.allTasks(),
                                     dreadServing: DreadServing(servedDay: today, lastPickWasDread: false))
        #expect(titles(next, store2) == ["dreadA"])
    }
}
