#if os(macOS)
import Testing
import Foundation
@testable import KronosCore

/// Hand-written expectation tables, compiled against the real `ProjectInsights` — never derived
/// from its own output. No store is needed: `KTask` is constructed bare and `waitsOnIDs` set
/// directly, the same way `SubtaskUndoTests`/`AuditUndoClobberTests` do for a pure dependency check.
@MainActor
struct ProjectInsightsTests {

    private func task(_ title: String, status: KStatus = .todo, waitsOn: [KTask] = [],
                      dueDay: Int? = nil, reviewRaw: Int = 0, sortIndex: Double = 0,
                      completedAt: Date? = nil) -> KTask {
        let t = KTask(title: title)
        t.status = status
        t.waitsOnIDs = waitsOn.map(\.id.uuidString).joined(separator: ",")
        t.dueDay = dueDay
        t.reviewRaw = reviewRaw
        t.sortIndex = sortIndex
        t.completedAt = completedAt
        return t
    }

    // MARK: - canStart

    @Test func openTaskWithNoDependencyCanStart() {
        let a = task("A")
        #expect(ProjectInsights.canStart(a, in: [a]))
    }

    @Test func openTaskWaitingOnAnOpenTaskCannotStart() {
        let a = task("A")
        let b = task("B", waitsOn: [a])
        #expect(!ProjectInsights.canStart(b, in: [a, b]))
    }

    @Test func openTaskWaitingOnADoneTaskCanStart() {
        let a = task("A", status: .done)
        let b = task("B", waitsOn: [a])
        #expect(ProjectInsights.canStart(b, in: [a, b]), "a closed blocker never blocks")
    }

    @Test func openTaskWaitingOnAnIDOutsideTheSetCanStart() {
        let phantom = task("ghost")
        let b = task("B", waitsOn: [phantom])
        // `phantom` is deliberately NOT included in the lookup set passed to canStart.
        #expect(ProjectInsights.canStart(b, in: [b]), "an unresolvable waits-on id never blocks")
    }

    @Test func aClosedTaskCanNeverStart() {
        let done = task("done", status: .done)
        let canceled = task("canceled", status: .canceled)
        #expect(!ProjectInsights.canStart(done, in: [done]))
        #expect(!ProjectInsights.canStart(canceled, in: [canceled]))
    }

    @Test func BREAK_wouldFailIfClosedBlockersCountedAsBlocking() {
        // Positive control for `openTaskWaitingOnADoneTaskCanStart`: inverting the done-task
        // status check must flip the result, proving the test can fail.
        let a = task("A", status: .inProgress)   // open, unlike the real test's .done
        let b = task("B", waitsOn: [a])
        #expect(!ProjectInsights.canStart(b, in: [a, b]), "control: an OPEN blocker must block")
    }

    // MARK: - openDependentsCount / isGate

    @Test func gateNeedsAtLeastTwoOpenDependents() {
        let x = task("X")
        let p1 = task("P1", waitsOn: [x])
        let p2 = task("P2", waitsOn: [x])
        let p3Done = task("P3", status: .done, waitsOn: [x])
        let all = [x, p1, p2, p3Done]
        #expect(ProjectInsights.openDependentsCount(of: x.id, in: all) == 2, "the done dependent does not count")
        #expect(ProjectInsights.isGate(x, in: all))
    }

    @Test func oneOpenDependentIsNotAGate() {
        let y = task("Y")
        let p1 = task("P1", waitsOn: [y])
        #expect(ProjectInsights.openDependentsCount(of: y.id, in: [y, p1]) == 1)
        #expect(!ProjectInsights.isGate(y, in: [y, p1]))
    }

    // MARK: - headerMetrics

    @Test func headerMetricsComposesProgressCanStartBlockedReviewAndDue() {
        let a = task("A", dueDay: 100, sortIndex: 1)                       // open, unblocked, due 100
        let b = task("B", waitsOn: [a], sortIndex: 2)                      // open, blocked by A
        let c = task("C", waitsOn: [a], sortIndex: 3)                      // open, blocked by A (A becomes a gate)
        let d = task("D", status: .inProgress, dueDay: 50, reviewRaw: ReviewState.awaitingCheck, sortIndex: 4)
        let e = task("E", status: .done, completedAt: Date())              // closed: counts toward progress only
        let f = task("F", status: .canceled)                               // excluded entirely
        let all = [a, b, c, d, e, f]

        let m = ProjectInsights.headerMetrics(tasks: all, today: 20000)

        #expect(m.doneCount == 1)
        #expect(m.totalCount == 5, "canceled F is excluded from the denominator")
        #expect(m.canStart.map(\.title) == ["A", "D"], "A and D are depth 0, in sortIndex order")
        #expect(m.blockedCount == 2, "B and C wait on the still-open A")
        #expect(m.readyForReviewCount == 1, "only D is awaitingCheck")
        #expect(m.nearestDueDay == 50, "D's due (50) beats A's (100); B and C have none")
        #expect(ProjectInsights.isGate(a, in: all), "A has two open dependents, B and C")
        #expect(!ProjectInsights.isGate(d, in: all))
    }

    @Test func headerMetricsCapsCanStartAtTheLimit() {
        let tasks = (0..<5).map { task("T\($0)", sortIndex: Double($0)) }
        let m = ProjectInsights.headerMetrics(tasks: tasks, today: 20000, canStartLimit: 3)
        #expect(m.canStart.count == 3)
        #expect(m.canStart.map(\.title) == ["T0", "T1", "T2"])
    }

    @Test func headerMetricsOnAnEmptyProjectIsAllZero() {
        let m = ProjectInsights.headerMetrics(tasks: [], today: 20000)
        #expect(m.totalCount == 0 && m.doneCount == 0 && m.canStart.isEmpty)
        #expect(m.blockedCount == 0 && m.readyForReviewCount == 0 && m.nearestDueDay == nil)
    }

    // MARK: - FlowLayout cross-check (v1.2 Phase 3 audit5 fold decision, ProjectInsights.swift's
    // own header comment)

    @Test func projectInsightsAgreesWithFlowLayoutDepthZeroOnAnAcyclicGraph() {
        let a = task("A", dueDay: 100, sortIndex: 1)
        let b = task("B", waitsOn: [a], sortIndex: 2)
        let c = task("C", waitsOn: [a], sortIndex: 3)
        let d = task("D", status: .inProgress, dueDay: 50, sortIndex: 4)
        let e = task("E", waitsOn: [b, d], sortIndex: 5)
        let all = [a, b, c, d, e]

        let flow = FlowLayout.build(tasks: all, activeRun: { _ in nil }, today: 20000, cap: nil)
        let flowCanStartIDs = Set(flow.columns.first(where: { $0.depth == 0 })?.taskIDs ?? [])
        var flowDependentCounts: [UUID: Int] = [:]
        for edge in flow.edges { flowDependentCounts[edge.from, default: 0] += 1 }

        // The fixture must mix depth-0 and non-depth-0 tasks, or this cross-check is vacuous.
        #expect(!flowCanStartIDs.isEmpty && flowCanStartIDs.count < all.count)

        for t in all {
            #expect(ProjectInsights.canStart(t, in: all) == flowCanStartIDs.contains(t.id),
                    "\(t.title): canStart must match FlowLayout's own depth-0 membership")
            let insightsGate = ProjectInsights.isGate(t, in: all)
            let flowGate = (flowDependentCounts[t.id] ?? 0) >= 2
            #expect(insightsGate == flowGate, "\(t.title): isGate must match FlowLayout's own edge-count gate rule")
        }
    }

    @Test func BREAK_wouldFailIfFlowLayoutEdgesCountedADoneDependent() {
        // Positive control for the isGate/edge-count comparison: X has 3 raw dependents, only 2
        // open (P3 is done) — both sides must agree X IS a gate (2 >= 2), proving the comparison
        // is not vacuously true by feeding it a done dependent FlowLayout must also exclude.
        let x = task("X")
        let p1 = task("P1", waitsOn: [x])
        let p2 = task("P2", waitsOn: [x])
        let p3Done = task("P3", status: .done, waitsOn: [x])
        let all = [x, p1, p2, p3Done]
        let flow = FlowLayout.build(tasks: all, activeRun: { _ in nil }, today: 20000, cap: nil)
        let flowDependents = flow.edges.filter { $0.from == x.id }.count
        #expect(flowDependents == 2, "FlowLayout must also exclude the done dependent from its edge list")
        #expect(ProjectInsights.isGate(x, in: all) == (flowDependents >= 2))
    }
}
#endif
