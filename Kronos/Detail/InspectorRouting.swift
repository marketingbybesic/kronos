// InspectorRouting: the ONE route into a task's details. A top-level task is selected; a child
// task selects its parent (the list context) and puts the inspector in child mode on the child.
// Every access point (ⓘ on step rows, palette/search result, the list's double-click / Enter /
// context menu) calls `openDetails(taskID:)`.
import Foundation
import KronosCore

extension AppModel {
    /// Opens `taskID` in the inspector. Returns false when the task is gone or deleted.
    @discardableResult
    func openDetails(taskID: UUID) -> Bool {
        guard let task = store.task(taskID), task.deletedAt == nil else { return false }
        selectedIDs = []
        if let parent = task.parent, parent.deletedAt == nil {
            selectedTaskID = parent.id
            inspectedSubtaskID = task.id
        } else {
            selectedTaskID = task.id
            inspectedSubtaskID = nil
        }
        return true
    }

    /// The task the inspector shows and every inspector action targets: the inspected child in
    /// child mode, else the selected task. Never use `selectedTaskID` for "the shown task".
    var inspectedTask: KTask? {
        let selected = selectedTaskID.flatMap { store.task($0) }
        return InspectedTask.resolve(selected: selected, inspectedChildID: inspectedSubtaskID)
    }

    var inspectedTaskID: UUID? { inspectedTask?.id }

    /// Leaves child mode for the parent task (breadcrumb, Esc). No-op outside child mode.
    func closeChildDetails() {
        if inspectedSubtaskID != nil {
            inspectedSubtaskID = nil
        } else if let id = selectedTaskID, let parent = store.task(id)?.parent {
            selectedTaskID = parent.id
        }
    }
}
