// Live steps for the planned day: a planned task shows in Today, H plans tomorrow and leaves the
// deadline empty, and one Cmd-Z undoes a Fresh start of five tasks. Run alone with
// `--only group:B1-TODAY`.
#if !RELEASE
import AppKit
import KronosCore

@MainActor
extension LiveUITest {
    static func b1TodaySteps(_ model: AppModel) async {
        await plannedTaskIsInToday(model)
        await hKeyPlansTomorrowAndKeepsTheDeadlineEmpty(model)
        await freshStartIsOneUndoStep(model)
    }

    private static var breakMode: Bool { ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil }

    private static func todayNumber() -> Int { Day.today(calendar: KronosLocale.calendar) }

    private static func todayRows(_ store: TaskStore) -> [KTask] {
        let today = todayNumber()
        return store.allTasks().filter { ScopeFilter.matches($0, scope: .today, today: today) }
    }

    /// A task with only a planned day (no deadline) is a member of Today, and is counted by the
    /// sidebar badge rule.
    private static func plannedTaskIsInToday(_ model: AppModel) async {
        let store = model.store
        let today = todayNumber()
        let t = store.create(title: "Planned for today probe")
        store.plan(t.id, day: today)
        model.didMutate()
        try? await Task.sleep(for: .milliseconds(300))
        let row = store.task(t.id)
        let member = row.map { ScopeFilter.matches($0, scope: .today, today: today) } ?? false
        let badge = row.map { ScopeFilter.countsInSidebar($0, scope: .today, today: today) } ?? false
        let wantDue: Int? = breakMode ? today : nil
        record("planned task with no deadline is in Today and counted",
               member && badge && row?.dueDay == wantDue,
               "member=\(member) badge=\(badge) due=\(String(describing: row?.dueDay)) planned=\(String(describing: row?.plannedDay))")
    }

    /// H on an overdue task: planned tomorrow, deadline untouched, out of Today; the real Cmd-Z
    /// brings it back.
    private static func hKeyPlansTomorrowAndKeepsTheDeadlineEmpty(_ model: AppModel) async {
        let store = model.store
        let today = todayNumber()
        let undated = store.create(title: "H undated probe")
        let late = store.create(title: "H overdue probe", status: .todo, priority: .none, dueDay: today - 5)
        store.snooze(undated.id)
        store.snooze(late.id)
        model.didMutate()
        try? await Task.sleep(for: .milliseconds(300))
        let u = store.task(undated.id), l = store.task(late.id)
        let stillUndated = u?.dueDay == nil && u?.plannedDay == today + 1
        let lateKept = l?.dueDay == today - 5 && l?.plannedDay == today + 1
        let out = !(l.map { ScopeFilter.matches($0, scope: .today, today: today) } ?? true)
        record("H plans tomorrow, leaves the deadline alone, takes the overdue task out of Today",
               stillUndated && lateKept && out,
               "undated=\(stillUndated) lateKept=\(lateKept) outOfToday=\(out)")

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nil)
        key("z", modifiers: .command, keyCode: 6)
        try? await Task.sleep(for: .milliseconds(500))
        if store.task(late.id)?.plannedDay != nil, let item = undoMenuItem(), let menu = item.menu {
            menu.performActionForItem(at: menu.index(of: item))
            try? await Task.sleep(for: .milliseconds(400))
        }
        let back = store.task(late.id)
        let backInToday = back.map { ScopeFilter.matches($0, scope: .today, today: today) } ?? false
        record("Cmd-Z after H puts the overdue task back in Today with no plan",
               back?.plannedDay == nil && back?.dueDay == today - 5 && backInToday,
               "planned=\(String(describing: back?.plannedDay)) due=\(String(describing: back?.dueDay)) inToday=\(backInToday)")
    }

    /// Five tasks four days late: Fresh start to tomorrow moves all five out of Today; ONE real
    /// Cmd-Z restores all five (deadline, carry and plan).
    private static func freshStartIsOneUndoStep(_ model: AppModel) async {
        let store = model.store
        let today = todayNumber()
        let ids = (1...5).map { i -> UUID in
            let t = store.create(title: "Earlier probe \(i)", status: .todo, priority: .none, dueDay: today - 4)
            store.updateNoUndo(t.id) { $0.carryCount = 4 }
            return t.id
        }
        model.didMutate()
        let earlier = TodayPartition.split(rows: todayRows(store).filter { ids.contains($0.id) }, today: today).earlier.count
        let depth = store.undoDepth
        store.freshStart(ids: ids, to: .tomorrow)
        model.didMutate()
        try? await Task.sleep(for: .milliseconds(300))
        // At the undo cap a push keeps the depth at the limit; `restored` below (one Cmd-Z brings
        // all five back) then proves the single step.
        let oneStep = depth >= TaskStore.undoLimit ? store.undoDepth == depth : store.undoDepth == depth + 1
        let gone = todayRows(store).filter { ids.contains($0.id) }.isEmpty
        let moved = ids.allSatisfy { store.task($0)?.plannedDay == today + 1 && store.task($0)?.carryCount == 0 }

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nil)
        key("z", modifiers: .command, keyCode: 6)
        try? await Task.sleep(for: .milliseconds(500))
        if store.task(ids[0])?.plannedDay != nil, let item = undoMenuItem(), let menu = item.menu {
            menu.performActionForItem(at: menu.index(of: item))
            try? await Task.sleep(for: .milliseconds(400))
        }
        let restored = ids.allSatisfy { id in
            let t = store.task(id)
            return t?.plannedDay == nil && t?.carryCount == 4 && t?.dueDay == today - 4
        }
        let wantEarlier = breakMode ? 4 : 5
        record("Fresh start: 5 tasks under Earlier, tomorrow moves all five, one Cmd-Z restores them",
               earlier == wantEarlier && oneStep && gone && moved && restored,
               "earlier=\(earlier) oneStep=\(oneStep) depth=\(depth) gone=\(gone) moved=\(moved) restored=\(restored)")
    }
}
#endif
