import Testing
import Foundation
@testable import KronosCore

/// The date-driven views read effectiveDue: Today / overdue / next-7 / "no deadline" windows,
/// sorting by deadline, the default priority-then-due order and the Impuls ranking.
/// Every expectation is a hand-written table; today is fixed at 2026-10-10.
@MainActor
@Suite("EffectiveDueViewsTests")
struct EffectiveDueViewsTests {

    private let today = SubtaskFixture.day("2026-10-10")

    private struct Row {
        let name: String
        let own: String?
        let steps: [(due: String?, done: Bool)]
        let inToday: Bool
        let inOverdue: Bool
        let inNext7: Bool
        let hasNoDeadline: Bool
    }

    private let windowTable: [Row] = [
        Row(name: "own future, no steps", own: "2026-10-12", steps: [],
            inToday: false, inOverdue: false, inNext7: true, hasNoDeadline: false),
        Row(name: "own future, undone step due today", own: "2026-10-12", steps: [("2026-10-10", false)],
            inToday: true, inOverdue: false, inNext7: true, hasNoDeadline: false),
        Row(name: "no own day, undone step overdue", own: nil, steps: [("2026-10-09", false)],
            inToday: true, inOverdue: true, inNext7: false, hasNoDeadline: false),
        Row(name: "own future, DONE step overdue", own: "2026-10-12", steps: [("2026-10-09", true)],
            inToday: false, inOverdue: false, inNext7: true, hasNoDeadline: false),
        Row(name: "nothing anywhere", own: nil, steps: [],
            inToday: false, inOverdue: false, inNext7: false, hasNoDeadline: true),
        Row(name: "own overdue, step later", own: "2026-10-05", steps: [("2026-10-20", false)],
            inToday: true, inOverdue: true, inNext7: false, hasNoDeadline: false),
        Row(name: "own far, step tomorrow", own: "2026-10-30", steps: [("2026-10-11", false)],
            inToday: false, inOverdue: false, inNext7: true, hasNoDeadline: false),
        Row(name: "no own day, only done steps", own: nil, steps: [("2026-10-09", true)],
            inToday: false, inOverdue: false, inNext7: false, hasNoDeadline: true),
        Row(name: "undated step does not count", own: nil, steps: [(nil, false)],
            inToday: false, inOverdue: false, inNext7: false, hasNoDeadline: true),
    ]

    private func make(_ store: TaskStore, _ title: String, own: String?, steps: [(due: String?, done: Bool)]) throws -> KTask {
        let t = store.createNoUndo(title: title)
        t.dueDay = own.map(SubtaskFixture.day)
        for step in steps {
            let s = try #require(store.addSubtaskNoUndo(t.id, title: "step"))
            s.dueDay = step.due.map(SubtaskFixture.day)
            s.isDone = step.done
        }
        return t
    }

    private func matches(_ window: KFilter.DueWindow, _ t: KTask) -> Bool {
        var f = KFilter.empty
        f.due = window
        return f.matches(t, today: today)
    }

    @Test func dueWindowsFollowTheEffectiveDay() throws {
        for row in windowTable {
            let store = try TaskStore(inMemory: true)
            let t = try make(store, row.name, own: row.own, steps: row.steps)
            #expect(matches(.today, t) == row.inToday, "\(row.name): today")
            #expect(matches(.overdue, t) == row.inOverdue, "\(row.name): overdue")
            #expect(matches(.next7, t) == row.inNext7, "\(row.name): next7")
            #expect(matches(.none, t) == row.hasNoDeadline, "\(row.name): none")
        }
    }

    @Test func todayAndNext7ScopesShowTheParentOnceAndIgnoreClosedTasks() throws {
        let store = try TaskStore(inMemory: true)
        let viaStep = try make(store, "via step", own: "2026-10-30", steps: [("2026-10-10", false)])
        let plain = try make(store, "plain future", own: "2026-10-30", steps: [])
        let overdueStep = try make(store, "overdue step", own: nil, steps: [("2026-10-01", false)])
        let doneStepOnly = try make(store, "done step", own: nil, steps: [("2026-10-10", true)])
        let doneParent = try make(store, "done parent", own: nil, steps: [("2026-10-10", false)])
        doneParent.status = .done
        let canceled = try make(store, "canceled", own: nil, steps: [("2026-10-10", false)])
        canceled.status = .canceled

        let all = [viaStep, plain, overdueStep, doneStepOnly, doneParent, canceled]
        #expect(all.filter { DueScope.isToday($0, today: today) }.map(\.title) == ["via step", "overdue step"])
        // Next 7 days: only a task whose effective day is in [today, today + 7].
        #expect(all.filter { DueScope.isNext7($0, today: today) }.map(\.title) == ["via step"])
    }

    @Test func customRangeUsesTheEffectiveDay() throws {
        let store = try TaskStore(inMemory: true)
        let t = try make(store, "Range", own: "2026-10-30", steps: [("2026-10-11", false)])
        var f = KFilter.empty
        f.due = .custom
        f.dueFrom = SubtaskFixture.day("2026-10-11")
        f.dueTo = SubtaskFixture.day("2026-10-12")
        #expect(f.matches(t, today: today))
        f.dueFrom = SubtaskFixture.day("2026-10-20")
        f.dueTo = nil
        #expect(f.matches(t, today: today) == false, "own day 10-30 is later than 10-20, but the step day 10-11 is the effective one")
    }

    // MARK: Sorting

    @Test func deadlineSortOrdersByEffectiveDay() throws {
        let store = try TaskStore(inMemory: true)
        let a = try make(store, "A own 15", own: "2026-10-15", steps: [])
        let b = try make(store, "B step 12", own: nil, steps: [("2026-10-12", false)])
        let c = try make(store, "C own 20 done step 11", own: "2026-10-20", steps: [("2026-10-11", true)])
        let d = try make(store, "D own 13", own: "2026-10-13", steps: [])
        let e = try make(store, "E nothing", own: nil, steps: [])
        let f = try make(store, "F own 25 step 10", own: "2026-10-25", steps: [("2026-10-10", false)])

        let sorted = KTaskSorter.sorted([a, b, c, d, e, f], by: [.asc(.deadline)])
        #expect(sorted.map(\.title) == ["F own 25 step 10", "B step 12", "D own 13", "A own 15", "C own 20 done step 11", "E nothing"])

        // Positive control: ordering by the OWN day alone gives a different list, so this test
        // cannot pass while the sort ignores subtasks.
        let ownOnly = [a, b, c, d, e, f].sorted { ($0.dueDay ?? Int.max) < ($1.dueDay ?? Int.max) }
        #expect(ownOnly.map(\.title) != sorted.map(\.title))
    }

    @Test func defaultPriorityThenDueOrderUsesTheEffectiveDay() throws {
        let store = try TaskStore(inMemory: true)
        let late = try make(store, "late own", own: "2026-10-20", steps: [])
        let viaStep = try make(store, "via step", own: "2026-10-30", steps: [("2026-10-11", false)])
        let sorted = [late, viaStep].sorted(by: Ordering.priorityThenDue)
        #expect(sorted.map(\.title) == ["via step", "late own"])
    }

    @Test func impulsRankingTieBreakUsesTheEffectiveDay() throws {
        let store = try TaskStore(inMemory: true)
        let late = try make(store, "late own", own: "2026-10-20", steps: [])
        let viaStep = try make(store, "via step", own: nil, steps: [("2026-10-11", false)])
        // Mid energy scores by priority alone, so the due tie-break decides.
        let picks = RankingEngine().candidates(energy: .mid, count: 2, maxDeep: true, today: today, tasks: [late, viaStep])
        #expect(picks.map(\.taskID) == [viaStep.id, late.id])
    }

    // MARK: Row indication

    @Test func dueDriverIsTheUndoneStepThatMovesTheDayEarlier() throws {
        let store = try TaskStore(inMemory: true)
        let t = try make(store, "Trip", own: "2026-10-20", steps: [("2026-10-10", false), ("2026-10-10", true), ("2026-10-18", false), (nil, false)])
        let steps = t.orderedSubtasks
        #expect(t.isDueDrivenBySubtask)
        #expect(steps.map { t.isDueDriver($0) } == [true, false, false, false])
    }

    @Test func noDriverWhenTheOwnDayAlreadyExplainsTheEffectiveDay() throws {
        let store = try TaskStore(inMemory: true)
        let sameDay = try make(store, "Same", own: "2026-10-10", steps: [("2026-10-10", false)])
        let laterStep = try make(store, "Later", own: "2026-10-10", steps: [("2026-10-14", false)])
        let none = try make(store, "None", own: nil, steps: [])
        for t in [sameDay, laterStep, none] {
            #expect(t.isDueDrivenBySubtask == false, Comment(rawValue: t.title))
            #expect(t.orderedSubtasks.contains { t.isDueDriver($0) } == false, Comment(rawValue: t.title))
        }
    }

    @Test func undatedTaskWithAStepDueIsDrivenByIt() throws {
        let store = try TaskStore(inMemory: true)
        let t = try make(store, "Undated", own: nil, steps: [("2026-10-12", false)])
        #expect(t.isDueDrivenBySubtask)
        #expect(t.isDueDriver(t.orderedSubtasks[0]))
    }
}
