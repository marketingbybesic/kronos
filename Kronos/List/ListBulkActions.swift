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
        case project(KProject?)
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
        guard n > 1 else { return }
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
            case .due(let day): for t in tasks { store.setDue(t.id, day: day) }
            case .priority(let p): for t in tasks { store.setPriority(t.id, p) }
            case .project(let p): for t in tasks { store.move(t.id, toProject: p) }
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
        model.didMutate()
        UndoToastCenter.shared.show(message)
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
