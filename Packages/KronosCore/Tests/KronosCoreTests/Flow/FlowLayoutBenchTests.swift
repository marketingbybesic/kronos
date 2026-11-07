#if os(macOS)
import Testing
import Foundation
@testable import KronosCore

@MainActor
@Suite struct FlowLayoutBenchTests {

    // MARK: - E6 capping

    @Test func cappingHidesDepthTwoAndAboveButShowAllRestoresIt() throws {
        let rig = try AgentRig()
        var independents: [KTask] = []
        for i in 0..<160 { independents.append(rig.store.createNoUndo(title: "Indep \(i)")) }
        let p1 = rig.store.createNoUndo(title: "P1")
        let p2 = rig.store.createNoUndo(title: "P2")
        let p3 = rig.store.createNoUndo(title: "P3")
        rig.store.setWaitsOnNoUndo(p2.id, [p1.id])
        rig.store.setWaitsOnNoUndo(p3.id, [p2.id])
        let tasks = independents + [p1, p2, p3]
        #expect(tasks.count == 163)

        let capped = FlowLayout.build(tasks: tasks, activeRun: { _ in nil }, today: rig.day, cap: 150)
        #expect(capped.cappedTotal == 163)
        #expect(capped.columns.allSatisfy { $0.depth <= 1 })
        #expect(!capped.columns.contains { $0.depth == 2 })

        // positive control: cap: nil on the exact same input restores the depth-2 column — proving the
        // cap, not a bug that always drops depth >= 2, is what gated it above.
        let uncapped = FlowLayout.build(tasks: tasks, activeRun: { _ in nil }, today: rig.day, cap: nil)
        #expect(uncapped.cappedTotal == nil)
        #expect(uncapped.columns.first { $0.depth == 2 }?.taskIDs == [p3.id])
    }

    // MARK: - performance budget

    @Test func fiveThousandTasksLayOutUnderThreeHundredMilliseconds() throws {
        let rig = try AgentRig()
        var tasks: [KTask] = []
        tasks.reserveCapacity(5000)

        // ~4800 independent depth-0 tasks, a sprinkling with ordoIndex/due set.
        for i in 0..<4800 {
            let t = rig.store.createNoUndo(title: "Bulk \(i)")
            if i % 200 == 0 {
                rig.store.updateNoUndo(t.id) { $0.ordoIndex = Double(i); $0.dueDay = rig.day + (i % 30) }
            }
            tasks.append(t)
        }

        // 48 short chains, 2-4 steps deep, so real depth > 0 columns exist too.
        for c in 0..<48 {
            let root = rig.store.createNoUndo(title: "Chain \(c) root")
            tasks.append(root)
            var prev = root
            let depth = 2 + (c % 3)
            for step in 0..<depth {
                let next = rig.store.createNoUndo(title: "Chain \(c) step \(step)")
                rig.store.setWaitsOnNoUndo(next.id, [prev.id])
                tasks.append(next)
                prev = next
            }
        }

        // one small cycle, which must not slow anything down.
        let x = rig.store.createNoUndo(title: "Cycle X")
        let y = rig.store.createNoUndo(title: "Cycle Y")
        rig.store.setWaitsOnNoUndo(x.id, [y.id])
        rig.store.setWaitsOnNoUndo(y.id, [x.id])
        tasks.append(x)
        tasks.append(y)

        while tasks.count < 5000 { tasks.append(rig.store.createNoUndo(title: "Pad \(tasks.count)")) }
        #expect(tasks.count == 5000)

        let start = Date()
        let result = FlowLayout.build(tasks: tasks, activeRun: { _ in nil }, today: rig.day)
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 0.3)
        #expect(!result.columns.isEmpty)
        // positive control: the budget is real, not vacuous — laying out a single task is dramatically
        // faster still, proving `elapsed` tracks real work rather than being a fixed constant.
        let trivialStart = Date()
        _ = FlowLayout.build(tasks: [tasks[0]], activeRun: { _ in nil }, today: rig.day)
        let trivialElapsed = Date().timeIntervalSince(trivialStart)
        #expect(trivialElapsed < elapsed)
    }
}
#endif
