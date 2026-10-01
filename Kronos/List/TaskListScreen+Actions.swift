// Kronos/List/TaskListScreen+Actions.swift
// Single-key row actions (snooze H, pin as focus F, priority 0-4). Every one raises the undo pill
// (audit D10: "undo after EVERY store change"); the pin is not a store change, so its toast
// carries its own undo (UndoToastCenter.show(_:customUndo:)).
import SwiftUI
import KronosCore

extension TaskListScreen {
    func snoozeTask(_ task: KTask) {
        let next = model.selectedTaskID == task.id ? ListCompletion.neighbourToSelect(after: task.id, model: model) : nil
        model.store.snooze(task.id)
        if let next { model.selectedTaskID = next }
        model.didMutate()
        UndoToastCenter.shared.show(String(format: String(localized: "undo.snoozed.name"), task.title))
    }

    func setPriority(_ task: KTask, _ priority: KPriority) {
        guard task.priority != priority else { return }
        model.store.setPriority(task.id, priority)
        model.didMutate()
        UndoToastCenter.shared.show(String(format: String(localized: "undo.priority.name"),
                                           ViewOptionsMapper.priorityName(priority), task.title))
    }

    func toggleFocusPin(_ task: KTask) {
        let previous = model.pinnedFocusTaskID
        if previous == task.id {
            model.pinnedFocusTaskID = nil
            UndoToastCenter.shared.show(String(format: String(localized: "undo.unpinned.name"), task.title),
                                        customUndo: { [model] in model.pinnedFocusTaskID = task.id })
        } else {
            model.pinnedFocusTaskID = task.id
            UndoToastCenter.shared.show(String(format: String(localized: "undo.pinned.name"), task.title),
                                        customUndo: { [model] in model.pinnedFocusTaskID = previous })
        }
    }
}
