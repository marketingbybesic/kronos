// Kronos/Triage/TriageGrammarActions.swift
// What each grammar key writes on the sort card (TriageKeyGrammar.swift names the keys).
// Keys that settle the task for now (tomorrow, snooze, waiting, someday) mark it as triaged in
// the same undo step and move to the next card; T only plans the day and keeps the card, so the
// fields can still be filled; delete and done leave the queue by themselves. Every write that
// changes something raises the undo pill; a key that would change nothing writes nothing.
import SwiftUI
import KronosCore

extension TriageFlowView {

    /// One grammar key on the sort card.
    func performSortAction(_ action: TriageKeyAction) {
        guard let task = current else { return }
        switch action {
        case .priority(let level): setPriority(KPriority(rawValue: level) ?? .none)
        case .effort(let size): setEffort(size.effort)
        case .pickDue: openDateField()
        case .pickProject: isPickingProject = true
        case .editFirstMove: openMoveField()
        case .clearDue: setDeadline(.none)
        case .refresh: if aiFailure == .noKey { TriageSettingsLink.openAI() } else { retryAI() }
        case .planToday: planToday(task)
        case .planTomorrow, .snooze: planTomorrow(task)
        case .waiting: toggleWaiting(task)
        case .someday: toggleSomeday(task)
        case .focusPin: togglePin(task)
        case .breakDown: breakDown(task)
        case .delete: deleteTask(task)
        case .done: completeTask(task)
        }
    }

    // MARK: Plan

    /// T: plan the task for today (the deadline stays). The card stays so the fields can follow.
    func planToday(_ task: KTask) {
        let today = Day.today(calendar: KronosLocale.calendar)
        guard task.plannedDay != today else { return }
        model.store.plan(task.id, day: today)
        model.didMutate()
        UndoToastCenter.shared.show(String(format: String(localized: "triage.pill.plannedtoday"), task.title))
    }

    /// ⇧T and H: plan it for tomorrow and go on (a task already planned for tomorrow still counts as
    /// decided: the plan write is a no-op, the triage flag and the next card still follow).
    func planTomorrow(_ task: KTask) {
        let tomorrow = Day.today(calendar: KronosLocale.calendar) + 1
        settle(task, pill: String(format: String(localized: "triage.pill.plannedtomorrow"), task.title)) {
            model.store.plan(task.id, day: tomorrow)
        }
    }

    // MARK: Park

    /// W: park it as waiting on someone, or release it again.
    func toggleWaiting(_ task: KTask) {
        if task.status == .waiting {
            model.store.setWaiting(task.id, false)
            model.didMutate()
            UndoToastCenter.shared.show(String(format: String(localized: "triage.pill.notwaiting"), task.title))
            return
        }
        settle(task, pill: String(format: String(localized: "triage.pill.waiting"), task.title)) {
            model.store.setWaiting(task.id, true)
        }
    }

    /// Y: move it to Someday (its plan goes), or bring a Someday task back to To do.
    func toggleSomeday(_ task: KTask) {
        if task.status == .someday {
            model.store.setStatus(task.id, .todo)
            model.didMutate()
            UndoToastCenter.shared.show(String(format: String(localized: "triage.pill.notsomeday"), task.title))
            return
        }
        settle(task, pill: String(format: String(localized: "triage.pill.someday"), task.title)) {
            model.store.setStatus(task.id, .someday)
            if task.plannedDay != nil { model.store.plan(task.id, day: nil) }
        }
    }

    /// One undo step: the write plus "this one has been through triage", then the next card.
    private func settle(_ task: KTask, pill: String, _ write: () -> Void) {
        model.store.groupedUndo("Sort") {
            write()
            model.store.update(task.id) { $0.needsTriage = false }
        }
        model.didMutate()
        UndoToastCenter.shared.show(pill)
        advance()
    }

    // MARK: Pin, break down, delete, done

    /// F: pin as the focus task, or unpin. Not a store change, so the pill carries its own undo.
    func togglePin(_ task: KTask) {
        let before = model.pinnedFocusTaskID
        let pinning = before != task.id
        model.pinnedFocusTaskID = pinning ? task.id : nil
        let format = pinning ? String(localized: "triage.pill.pinned") : String(localized: "triage.pill.unpinned")
        UndoToastCenter.shared.show(String(format: format, task.title), customUndo: { model.pinnedFocusTaskID = before })
    }

    /// B: leave the card, open the task in the inspector and ask its steps section for the
    /// break-down preview (raw name `kronosBreakdownRequested`, userInfo `taskID`, posted on the
    /// next run-loop turn after the inspector has the task).
    func breakDown(_ task: KTask) {
        let id = task.id
        onClose()
        guard model.openDetails(taskID: id) else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.breakdownRequested, object: nil, userInfo: ["taskID": id])
        }
    }

    static var breakdownRequested: Notification.Name { Notification.Name("kronosBreakdownRequested") }

    /// ⌫: delete it (one undo step, pill), next card.
    func deleteTask(_ task: KTask) {
        model.store.softDelete(task.id)
        model.didMutate()
        UndoToastCenter.shared.show(String(format: String(localized: "undo.deleted.name"), task.title))
        advance()
    }

    /// Space: complete it (one undo step, pill), next card.
    func completeTask(_ task: KTask) {
        model.store.complete(task.id)
        if model.pinnedFocusTaskID == task.id { model.pinnedFocusTaskID = nil }
        model.didMutate()
        UndoToastCenter.shared.show(String(format: String(localized: "undo.completed.name"), task.title))
        advance()
    }
}

extension TriageEffortKey {
    var effort: KEffort {
        switch self {
        case .small: return .s
        case .medium: return .m
        case .large: return .l
        }
    }
}
