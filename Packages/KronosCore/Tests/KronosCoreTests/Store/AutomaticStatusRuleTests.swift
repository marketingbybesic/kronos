// An open, not-waiting task follows its own due day automatically: due day SET -> .todo,
// due day CLEARED -> .someday. A waiting task is never auto-reclassified by this rule at all
// — Someday is only for a task that is open and truly dateless, not one that is blocked on
// someone else. The rule lives in ONE place, `TaskStore.applyAutomaticStatusRule` (called
// from `mutateUndoable`, the single choke point every mutator — undoable or not — passes
// through), not duplicated per caller. This file is the hand-written truth table for it
// (status x dueBefore x dueAfter x waiting), plus one test per bypass path found: `applyTriage`,
// `snooze`, and MCP's `update_task`.
import Testing
import Foundation
@testable import KronosCore

@MainActor
struct AutomaticStatusRuleTests {

    private func makeStore() throws -> TaskStore { try TaskStore(inMemory: true) }

    // MARK: - Hand-tabled: status x dueBefore x dueAfter x waiting
    //
    // Each row is one `store.update` call. `nil` "before" means the task was created
    // without a due day; "after" is what the closure sets. Expected is the status AFTER.

    @Test func openTodoDueSetBecomesTodo() throws {
        let store = try makeStore()
        let t = store.create(title: "a", status: .todo, dueDay: nil)
        store.setDue(t.id, day: Day.today())
        #expect(store.task(t.id)?.status == .todo)
    }

    @Test func openTodoDueClearedBecomesSomeday() throws {
        let store = try makeStore()
        let t = store.create(title: "a", status: .todo, dueDay: Day.today())
        store.setDue(t.id, day: nil)
        #expect(store.task(t.id)?.status == .someday)
        // O5: leaving .someday must also drop the row out of ORDO.
        store.sendToOrdo(t.id)
        store.setDue(t.id, day: nil) // no-op due change: rule must not re-fire, ordoIndex stays
        #expect(store.task(t.id)?.ordoIndex != nil)
        store.setDue(t.id, day: Day.today() + 3)
        store.setDue(t.id, day: nil)
        #expect(store.task(t.id)?.ordoIndex == nil)
    }

    @Test func inProgressDueClearedBecomesSomeday() throws {
        let store = try makeStore()
        let t = store.create(title: "a", status: .todo, dueDay: Day.today())
        store.setStatus(t.id, .inProgress)
        store.setDue(t.id, day: nil)
        #expect(store.task(t.id)?.status == .someday)
    }

    @Test func inProgressDueSetStaysTodoNotInProgress() throws {
        // The rule's "due set" target is always .todo per brief line 15, even from
        // .inProgress — it only fires when the due day itself changed, and .inProgress
        // already implies a due day was not what put it there, so this documents the
        // literal rule rather than inventing an .inProgress-preserving special case.
        let store = try makeStore()
        let t = store.create(title: "a", status: .todo, dueDay: nil)
        store.setStatus(t.id, .inProgress)
        store.setDue(t.id, day: Day.today())
        #expect(store.task(t.id)?.status == .todo)
    }

    @Test func waitingNeverAutoChangesOnDueEdit() throws {
        let store = try makeStore()
        let t = store.create(title: "a", status: .todo, dueDay: Day.today())
        store.setWaiting(t.id, true)
        #expect(store.task(t.id)?.status == .waiting)
        store.setDue(t.id, day: nil)
        #expect(store.task(t.id)?.status == .waiting)
        store.setDue(t.id, day: Day.today() + 5)
        #expect(store.task(t.id)?.status == .waiting)
    }

    @Test func closedStatusesNeverAutoChangeOnDueEdit() throws {
        let store = try makeStore()
        let done = store.create(title: "done", status: .todo, dueDay: Day.today())
        store.complete(done.id)
        store.setDue(done.id, day: nil)
        #expect(store.task(done.id)?.status == .done)

        let canceled = store.create(title: "canceled", status: .todo, dueDay: Day.today())
        store.setStatus(canceled.id, .canceled)
        store.setDue(canceled.id, day: nil)
        #expect(store.task(canceled.id)?.status == .canceled)
    }

    @Test func editThatDoesNotTouchDueDayNeverChangesStatus() throws {
        // Renaming an undated todo task must not move it — the rule fires only when
        // THIS mutation changed the due day, never as a side effect of any other edit.
        let store = try makeStore()
        let t = store.create(title: "Undated", status: .todo, dueDay: nil)
        store.update(t.id) { $0.title = "Undated, renamed" }
        #expect(store.task(t.id)?.status == .todo)
        #expect(store.task(t.id)?.title == "Undated, renamed")
    }

    @Test func settingTheSameDueDayIsNotAChange() throws {
        let store = try makeStore()
        let t = store.create(title: "a", status: .todo, dueDay: Day.today())
        store.setDue(t.id, day: Day.today()) // same value
        #expect(store.task(t.id)?.status == .todo)
    }

    @Test func noMigrationOfExistingTasksAtLaunch() throws {
        // Creating a task with no due day (the store's own create path, not `update`)
        // must NOT retroactively demote it — the rule only reacts to a due-day EDIT.
        let store = try makeStore()
        let t = store.create(title: "Freshly created, no date", status: .todo, dueDay: nil)
        #expect(store.task(t.id)?.status == .todo)
    }

    // MARK: - Bypass paths: every mutator that writes `dueDay` outside the normal `update` path
    //
    // Every one of these funnels through `mutateUndoable` too: `applyTriage`'s inline
    // `t.dueDay = day` write happens INSIDE an `update(id) { ... }` closure (not a raw
    // model write), `snooze` already calls `update`, and MCP's `updateNoUndo` -> `withoutUndo`
    // -> `updateIncludingDeleted` -> `mutateUndoable`. None of the three needed a code
    // change to obey the rule — this proves it, rather than asserting it from reading.

    @Test func applyTriageSettingDueMovesUndatedTodoToTodo() throws {
        let store = try makeStore()
        let t = store.create(title: "Needs triage", status: .todo, dueDay: nil)
        let result = TriageResult(project: nil, priority: 0, due: Day.iso(Day.today() + 2),
                                  depth: .shallow, estimateMinutes: 0, energyKind: .deepWork,
                                  firstMove: "", labels: [], rationale: "", proposedRule: nil,
                                  effort: nil, reason: "", version: 1)
        store.applyTriage(result, to: t.id)
        #expect(store.task(t.id)?.dueDay != nil)
        #expect(store.task(t.id)?.status == .todo)
    }

    @Test func snoozeOnAnUndatedWaitingTaskNeverAutoChangesStatus() throws {
        let store = try makeStore()
        let t = store.create(title: "Blocked", status: .todo, dueDay: nil)
        store.setWaiting(t.id, true)
        store.snooze(t.id) // sets dueDay = today + 1 when nil
        #expect(store.task(t.id)?.dueDay != nil)
        #expect(store.task(t.id)?.status == .waiting) // waiting never auto-changes
    }

    @Test func snoozeOnAnOpenTaskSetsDueAndKeepsTodo() throws {
        let store = try makeStore()
        let t = store.create(title: "a", status: .todo, dueDay: nil)
        store.snooze(t.id)
        #expect(store.task(t.id)?.dueDay != nil)
        #expect(store.task(t.id)?.status == .todo)
    }

    @Test func mcpUpdateTaskClearingDueDemotesToSomeday() throws {
        let store = try makeStore()
        let dispatcher = MCPDispatcher(store: store, ranking: RankingEngine())
        let t = store.createNoUndo(title: "Has a due date")
        store.updateNoUndo(t.id) { $0.dueDay = Day.today() }
        #expect(store.task(t.id)!.status == .todo)

        let argsData = try JSONSerialization.data(withJSONObject: ["id": t.id.uuidString])
        var argsObj = try JSONSerialization.jsonObject(with: argsData) as! [String: Any]
        argsObj["due"] = NSNull()
        let envelope: [String: Any] = ["name": "update_task", "arguments": argsObj]
        let paramsData = try JSONSerialization.data(withJSONObject: envelope)
        let request = MCPRequest(id: .number(1), method: "tools/call", paramsData: paramsData)
        _ = dispatcher.handle(request)

        #expect(store.task(t.id)!.dueDay == nil)
        #expect(store.task(t.id)!.status == .someday)
    }

    @Test func mcpUpdateTaskSettingDuePromotesUndatedSomedayToTodo() throws {
        let store = try makeStore()
        let dispatcher = MCPDispatcher(store: store, ranking: RankingEngine())
        let t = store.createNoUndo(title: "Parked")
        store.updateNoUndo(t.id) { $0.dueDay = Day.today() } // any due-day change fires the rule
        store.updateNoUndo(t.id) { $0.dueDay = nil }
        #expect(store.task(t.id)!.status == .someday)

        let argsObj: [String: Any] = ["id": t.id.uuidString, "due": Day.iso(Day.today() + 1)]
        let envelope: [String: Any] = ["name": "update_task", "arguments": argsObj]
        let paramsData = try JSONSerialization.data(withJSONObject: envelope)
        let request = MCPRequest(id: .number(1), method: "tools/call", paramsData: paramsData)
        _ = dispatcher.handle(request)

        #expect(store.task(t.id)!.status == .todo)
    }
}
