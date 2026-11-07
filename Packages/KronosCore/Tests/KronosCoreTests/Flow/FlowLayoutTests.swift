#if os(macOS)
import Testing
import Foundation
@testable import KronosCore

@MainActor
@Suite struct FlowLayoutTests {

    // MARK: - depths, edges, columns

    @Test func chainDepthsAndEdgesMatchTheHandDrawnGraph() throws {
        let rig = try AgentRig()
        let a = rig.store.createNoUndo(title: "A")
        let b = rig.store.createNoUndo(title: "B")
        let c = rig.store.createNoUndo(title: "C")
        let d = rig.store.createNoUndo(title: "D")
        rig.store.setWaitsOnNoUndo(b.id, [a.id])
        rig.store.setWaitsOnNoUndo(c.id, [b.id])
        let result = FlowLayout.build(tasks: [a, b, c, d], activeRun: { _ in nil }, today: rig.day)
        let byDepth = Dictionary(uniqueKeysWithValues: result.columns.map { ($0.depth, Set($0.taskIDs)) })
        #expect(byDepth[0] == Set([a.id, d.id]))
        #expect(byDepth[1] == Set([b.id]))
        #expect(byDepth[2] == Set([c.id]))
        #expect(Set(result.edges) == Set([FlowLayout.Edge(from: a.id, to: b.id), FlowLayout.Edge(from: b.id, to: c.id)]))
        #expect(result.cycles.isEmpty)
        #expect(result.cappedTotal == nil)
        // positive control: depth 0 and depth 1 are genuinely different sets, not one bucket catching everything.
        #expect(byDepth[0] != byDepth[1])
        // positive control: D, which waits on nothing, draws no edge at all.
        #expect(!result.edges.contains { $0.from == d.id || $0.to == d.id })
    }

    // MARK: - cycle defense

    @Test func aTwoCycleTerminatesAndPinsBothToDepthZero() throws {
        let rig = try AgentRig()
        let x = rig.store.createNoUndo(title: "X")
        let y = rig.store.createNoUndo(title: "Y")
        // setWaitsOnNoUndo refuses anything that would close a loop (the UI picker's own cycle
        // guard) — so a genuine cycle is built the way JSON import actually produces one: raw
        // waitsOnIDs field writes with no guard at all.
        rig.store.updateNoUndo(x.id) { $0.waitsOnIDs = y.id.uuidString }
        rig.store.updateNoUndo(y.id) { $0.waitsOnIDs = x.id.uuidString }
        // reaching this line at all (no hang, no crash) already proves termination on the back-edge.
        let result = FlowLayout.build(tasks: [x, y], activeRun: { _ in nil }, today: rig.day)
        let byDepth = Dictionary(uniqueKeysWithValues: result.columns.map { ($0.depth, Set($0.taskIDs)) })
        #expect(byDepth[0] == Set([x.id, y.id]))
        #expect(byDepth[1] == nil, "no column above depth 0 exists for a pure 2-cycle")
        #expect(!result.cycles.isEmpty && Set(result.cycles).isSubset(of: [x.id, y.id]))
        #expect(result.edges.isEmpty, "a cycle-pinned pair draws no prerequisite edges at all")
        // positive control: a non-cyclic task added to the same build is left alone, not swept into cycles too.
        let z = rig.store.createNoUndo(title: "Z")
        let result2 = FlowLayout.build(tasks: [x, y, z], activeRun: { _ in nil }, today: rig.day)
        #expect(!result2.cycles.contains(z.id))
    }

    // MARK: - ordering: running first

    @Test func runningSortsFirstRegardlessOfOrdoOrDue() throws {
        let rig = try AgentRig()
        let agent = rig.agent("codex")
        let running = rig.store.createNoUndo(title: "Running task")
        let idle = rig.store.createNoUndo(title: "Idle task")
        rig.store.updateNoUndo(idle.id) { $0.ordoIndex = 0.1; $0.dueDay = rig.day - 5 }
        _ = try rig.runs.start(taskID: running.id, agent: agent, launchedByKronos: false)
        let result = FlowLayout.build(tasks: [running, idle], activeRun: { rig.runs.activeRun(taskID: $0) }, today: rig.day)
        let column0 = try #require(result.columns.first { $0.depth == 0 })
        #expect(column0.taskIDs == [running.id, idle.id])
        // positive control: with no run active at all, the earlier-ordoIndex task sorts first instead —
        // the running-first rule, not a fixed id/creation order, is what put running ahead above.
        let result2 = FlowLayout.build(tasks: [running, idle], activeRun: { _ in nil }, today: rig.day)
        let column0b = try #require(result2.columns.first { $0.depth == 0 })
        #expect(column0b.taskIDs == [idle.id, running.id])
    }

    // MARK: - ordering: ordoIndex then effectiveDue

    @Test func ordoIndexWinsOverDueThenDueBreaksRemainingTies() throws {
        let rig = try AgentRig()
        let earlyOrdoLateDue = rig.store.createNoUndo(title: "Early ordo, late due")
        let lateOrdoEarlyDue = rig.store.createNoUndo(title: "Late ordo, early due")
        rig.store.updateNoUndo(earlyOrdoLateDue.id) { $0.ordoIndex = 1; $0.dueDay = rig.day + 30 }
        rig.store.updateNoUndo(lateOrdoEarlyDue.id) { $0.ordoIndex = 2; $0.dueDay = rig.day - 30 }
        let byOrdo = FlowLayout.build(tasks: [earlyOrdoLateDue, lateOrdoEarlyDue], activeRun: { _ in nil }, today: rig.day)
        let ordoColumn = try #require(byOrdo.columns.first { $0.depth == 0 })
        #expect(ordoColumn.taskIDs == [earlyOrdoLateDue.id, lateOrdoEarlyDue.id])

        let earlyDue = rig.store.createNoUndo(title: "Early due")
        let lateDue = rig.store.createNoUndo(title: "Late due")
        rig.store.updateNoUndo(earlyDue.id) { $0.dueDay = rig.day }
        rig.store.updateNoUndo(lateDue.id) { $0.dueDay = rig.day + 10 }
        let byDue = FlowLayout.build(tasks: [earlyDue, lateDue], activeRun: { _ in nil }, today: rig.day)
        let dueColumn = try #require(byDue.columns.first { $0.depth == 0 })
        #expect(dueColumn.taskIDs == [earlyDue.id, lateDue.id])
        // positive control: swapping the input array order still yields the due-ordered result —
        // proving this follows the due date, not array/creation order.
        let swapped = try #require(FlowLayout.build(tasks: [lateDue, earlyDue], activeRun: { _ in nil }, today: rig.day)
            .columns.first { $0.depth == 0 })
        #expect(swapped.taskIDs == [earlyDue.id, lateDue.id])
    }

    // MARK: - done-today inclusion

    @Test func aDoneTaskIsPinnedToDepthZeroWithoutWalkingItsWaitsOn() throws {
        let rig = try AgentRig()
        let blocker = rig.store.createNoUndo(title: "Still open blocker")
        let done = rig.store.createNoUndo(title: "Done today")
        rig.store.setWaitsOnNoUndo(done.id, [blocker.id])
        rig.store.completeNoUndo(done.id)
        let result = FlowLayout.build(tasks: [blocker, done], activeRun: { _ in nil }, today: rig.day)
        let byDepth = Dictionary(uniqueKeysWithValues: result.columns.map { ($0.depth, Set($0.taskIDs)) })
        #expect(byDepth[0] == Set([blocker.id, done.id]))
        #expect(byDepth[1] == nil)
        // positive control: the same waits-on, on a still-open task instead, genuinely produces depth 1 —
        // proving the status check short-circuits the walk, rather than a bug that always ignores waitsOn.
        let open = rig.store.createNoUndo(title: "Still open dependent")
        rig.store.setWaitsOnNoUndo(open.id, [blocker.id])
        let result2 = FlowLayout.build(tasks: [blocker, open], activeRun: { _ in nil }, today: rig.day)
        let byDepth2 = Dictionary(uniqueKeysWithValues: result2.columns.map { ($0.depth, Set($0.taskIDs)) })
        #expect(byDepth2[1] == Set([open.id]))
    }

    // MARK: - upstream / downstream

    @Test func upstreamAndDownstreamReflectTheChainGraph() throws {
        let rig = try AgentRig()
        let a = rig.store.createNoUndo(title: "A")
        let b = rig.store.createNoUndo(title: "B")
        let c = rig.store.createNoUndo(title: "C")
        let d = rig.store.createNoUndo(title: "D")
        rig.store.setWaitsOnNoUndo(b.id, [a.id])
        rig.store.setWaitsOnNoUndo(c.id, [b.id])
        let result = FlowLayout.build(tasks: [a, b, c, d], activeRun: { _ in nil }, today: rig.day)
        #expect(FlowLayout.upstream(of: c.id, edges: result.edges) == Set([a.id, b.id]))
        #expect(FlowLayout.downstream(of: a.id, edges: result.edges) == Set([b.id, c.id]))
        #expect(FlowLayout.upstream(of: a.id, edges: result.edges).isEmpty)
        #expect(FlowLayout.downstream(of: d.id, edges: result.edges).isEmpty)
        // positive control: B sits strictly between A and C — exactly one upstream, one downstream —
        // proving the walk neither over- nor under-collects along the chain.
        #expect(FlowLayout.upstream(of: b.id, edges: result.edges) == Set([a.id]))
        #expect(FlowLayout.downstream(of: b.id, edges: result.edges) == Set([c.id]))
    }
}
#endif
