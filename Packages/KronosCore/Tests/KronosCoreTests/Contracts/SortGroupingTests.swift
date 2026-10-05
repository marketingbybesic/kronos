import Testing
import Foundation
@testable import KronosCore

/// The missing-value group: which sort key groups, and how rows split. Expected lists are written by hand.
@MainActor
@Suite("SortGroupingTests")
struct SortGroupingTests {

    @Test("which sort keys map to a field triage can fill")
    func fillKindTable() {
        let table: [(KSortKey, TriageFieldKind?)] = [
            (.manual, nil), (.title, nil), (.status, nil), (.priority, nil), (.createdAt, nil),
            (.updatedAt, nil), (.completedAt, nil), (.area, nil),
            (.deadline, .due), (.effort, .effort), (.estimateMinutes, .estimateMinutes),
            (.depth, .depth), (.project, .project), (.label, .labels),
        ]
        for (key, kind) in table {
            #expect(SortGrouping.fillKind(for: key) == kind, "key \(key)")
        }
        // Every sort key is covered by the table.
        #expect(table.count == KSortKey.allCases.count)
    }

    @Test("only the FIRST sort key groups, and never a manual order")
    func missingKeyIsTheFirstKey() {
        #expect(SortGrouping.missingKey(for: [.asc(.deadline)]) == .deadline)
        #expect(SortGrouping.missingKey(for: [.desc(.effort), .asc(.title)]) == .effort)
        #expect(SortGrouping.missingKey(for: [.asc(.priority), .asc(.deadline)]) == nil)
        #expect(SortGrouping.missingKey(for: KSortDescriptor.default) == nil)
        #expect(SortGrouping.missingKey(for: []) == nil)
    }

    /// d1 (due), n1 (none), d2 (due), n2 (none), in this order, already sorted by something else.
    private func rows() throws -> (store: TaskStore, rows: [KTask]) {
        let s = try TaskStore(inMemory: true)
        let day = Day.today()
        let d1 = s.createNoUndo(title: "d1"), n1 = s.createNoUndo(title: "n1")
        let d2 = s.createNoUndo(title: "d2"), n2 = s.createNoUndo(title: "n2")
        d1.dueDay = day + 1; d2.dueDay = day + 5
        d1.effortRaw = KEffort.s.rawValue; n1.effortRaw = KEffort.none.rawValue
        d2.effortRaw = KEffort.xl.rawValue; n2.effortRaw = KEffort.none.rawValue
        return (s, [d1, n1, d2, n2])
    }

    @Test("split keeps each part in its order: deadline and effort")
    func splitDeadlineAndEffort() throws {
        let (store, r) = try rows()
        let byDue = SortGrouping.split(rows: r, key: .deadline)
        #expect(byDue.present.map(\.title) == ["d1", "d2"])
        #expect(byDue.missing.map(\.title) == ["n1", "n2"])
        let byEffort = SortGrouping.split(rows: r, key: .effort)
        #expect(byEffort.present.map(\.title) == ["d1", "d2"])
        #expect(byEffort.missing.map(\.title) == ["n1", "n2"])
        #expect(store.undoDepth == 0)   // keeps the store alive while its tasks are read
    }

    @Test("project and estimate: a task without one is missing")
    func splitProjectAndEstimate() throws {
        let s = try TaskStore(inMemory: true)
        let p = s.createProject(name: "Acme")
        let a = s.createNoUndo(title: "a", project: p), b = s.createNoUndo(title: "b")
        a.estimateMinutes = 30
        #expect(SortGrouping.split(rows: [b, a], key: .project).present.map(\.title) == ["a"])
        #expect(SortGrouping.split(rows: [b, a], key: .project).missing.map(\.title) == ["b"])
        #expect(SortGrouping.split(rows: [b, a], key: .estimateMinutes).missing.map(\.title) == ["b"])
        #expect(s.allTasks().count == 2)
    }

    @Test("priority none is a real value, so nothing is missing; a key nobody lacks leaves the missing part empty")
    func priorityNeverMissing() throws {
        let (store, r) = try rows()
        let byPriority = SortGrouping.split(rows: r, key: .priority)
        #expect(byPriority.present.count == 4)
        #expect(byPriority.missing.isEmpty)
        // Positive control: the same rows do split on a key some of them lack.
        #expect(!SortGrouping.split(rows: r, key: .deadline).missing.isEmpty)
        #expect(store.undoDepth == 0)
    }
}
