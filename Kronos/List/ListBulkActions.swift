// Kronos/List/ListBulkActions.swift
// Every bulk action on the multi-selection (`model.selectedIDs`) — the floating bar, the
// list keys and the palette all call `ListBulk.apply`, so there is exactly one place that
// decides what "complete / delete / move 3 tasks" means. Each call wraps its writes in the
// store's `groupedUndo`, so one ⌘Z (or the undo pill) reverts the whole action.
import Foundation
import KronosCore

@MainActor
enum ListBulk {
    enum Change {
        case due(Int?)
        case priority(KPriority)
        case effort(KEffort)
        case status(KStatus)
        case project(KProject?)
        /// Plans every task for the day (plannedDay; deadlines untouched). nil clears the plan.
        case plan(Int?)
        /// Adds the label to every task, or removes it from every task when all carry it.
        case toggleLabel(KLabel)
        /// Parks every task as waiting; when ALL are already waiting, releases them (W).
        case toggleWaiting
        /// Moves every task to Someday; when ALL are already there, back to To do (Y).
        case toggleSomeday
        /// Completes every open task; when ALL are already done, reopens them instead (Space).
        case toggleDone
        case delete
        case snooze
    }

    /// Runs `change` on every selected task as one undo step. No-op below two tasks: a single
    /// selection keeps its own single-task paths (and their toasts).
    static func apply(_ change: Change, model: AppModel) {
        let tasks = model.selectedIDs.compactMap { model.store.task($0) }
        let n = tasks.count
        guard n > 1, changesSomething(change, tasks) else { return }
        let message: String
        switch change {
        case .toggleDone:
            message = tasks.allSatisfy({ $0.status == .done }) ? reopened(n) : completed(n)
        case .delete: message = deleted(n)
        default: message = updated(n)
        }
        let store = model.store
        store.groupedUndo(message) {
            switch change {
            case .due(let day): for t in tasks where t.dueDay != day { store.setDue(t.id, day: day) }
            case .priority(let p): for t in tasks where t.priority != p { store.setPriority(t.id, p) }
            case .effort(let e): for t in tasks where t.effort != e { store.setEffort(t.id, e) }
            case .status(let st):
                // Waiting goes through its own writer: it also plans the check-in day.
                for t in tasks where t.status != st { if st == .waiting { store.setWaiting(t.id, true) } else { store.setStatus(t.id, st) } }
            case .project(let p): for t in tasks where t.projectID != p?.id { store.move(t.id, toProject: p) }
            case .plan(let day): store.plan(tasks.map(\.id), day: day)
            case .toggleLabel(let label):
                let allCarry = tasks.allSatisfy { ($0.labels ?? []).contains { $0.id == label.id } }
                for t in tasks { if allCarry { store.removeLabel(label, from: t.id) } else { store.addLabel(label, to: t.id) } }
            case .toggleWaiting:
                let allWaiting = tasks.allSatisfy { $0.status == .waiting }
                for t in tasks where t.status != .done { store.setWaiting(t.id, !allWaiting) }
            case .toggleSomeday:
                let allSomeday = tasks.allSatisfy { $0.status == .someday }
                for t in tasks where t.status != .done { store.setStatus(t.id, allSomeday ? .todo : .someday) }
            case .snooze: for t in tasks { store.snooze(t.id) }
            case .delete: for t in tasks { store.softDelete(t.id) }
            case .toggleDone:
                if tasks.allSatisfy({ $0.status == .done }) {
                    for t in tasks { store.reopen(t.id) }
                } else {
                    for t in tasks where t.status != .done { store.complete(t.id) }
                }
            }
        }
        if case .delete = change {
            model.selectedIDs = []
            model.selectedTaskID = nil
        }
        model.commit(message)
    }

    /// False when every task already holds the value: nothing is written and no pill shows.
    static func changesSomething(_ change: Change, _ tasks: [KTask]) -> Bool {
        let today = Day.today()
        switch change {
        case .due(let day): return tasks.contains { $0.dueDay != day }
        case .priority(let p): return tasks.contains { $0.priority != p }
        case .effort(let e): return tasks.contains { $0.effort != e }
        case .status(let st): return tasks.contains { $0.status != st }
        case .project(let p): return tasks.contains { $0.projectID != p?.id }
        case .plan(let day): return tasks.contains { $0.plannedDay != day }
        case .snooze: return tasks.contains { $0.plannedDay != today + 1 }
        case .toggleWaiting, .toggleSomeday: return tasks.contains { $0.status != .done }
        case .toggleLabel, .toggleDone, .delete: return true
        }
    }

    // MARK: Counts — literal plural keys (one/few/many), never a built key string.

    static func selected(_ n: Int) -> String {
        KPlural.hr(n, one: String(localized: "list.bulk.selected.one"),
                   few: String(localized: "list.bulk.selected.few"), many: String(localized: "list.bulk.selected.many"))
    }
    /// "5 tasks selected": the inspector's multi-selection headline.
    static func selectedTasks(_ n: Int) -> String {
        KPlural.hr(n, one: String(localized: "list.bulk.panel.one"),
                   few: String(localized: "list.bulk.panel.few"), many: String(localized: "list.bulk.panel.many"))
    }
    static func completed(_ n: Int) -> String {
        KPlural.hr(n, one: String(localized: "list.bulk.done.one"),
                   few: String(localized: "list.bulk.done.few"), many: String(localized: "list.bulk.done.many"))
    }
    static func reopened(_ n: Int) -> String {
        KPlural.hr(n, one: String(localized: "list.bulk.reopened.one"),
                   few: String(localized: "list.bulk.reopened.few"), many: String(localized: "list.bulk.reopened.many"))
    }
    static func deleted(_ n: Int) -> String {
        KPlural.hr(n, one: String(localized: "list.bulk.deleted.one"),
                   few: String(localized: "list.bulk.deleted.few"), many: String(localized: "list.bulk.deleted.many"))
    }
    static func updated(_ n: Int) -> String {
        KPlural.hr(n, one: String(localized: "list.bulk.updated.one"),
                   few: String(localized: "list.bulk.updated.few"), many: String(localized: "list.bulk.updated.many"))
    }
}
