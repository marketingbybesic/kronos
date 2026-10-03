// Kronos/Shared/AppModel+OpenTask.swift
// "Open this task by id" from outside the list: a kronos://open link, a Spotlight result, the
// Dock menu. It picks the list that shows the row (a child's row is its parent's) and then goes
// through the one details route, `openDetails(taskID:)`.
import Foundation
import KronosCore

extension AppModel {
    /// Returns false when the id is gone (deleted or never existed) and nothing was changed.
    @discardableResult
    func openTaskByID(_ id: UUID) -> Bool {
        guard let task = store.task(id), task.deletedAt == nil else { return false }
        if let parent = task.parent {
            if let project = parent.project {
                scope = .project(project.id)
            } else {
                scope = KStatus.open.contains(parent.status) ? .inbox : .all
            }
        } else {
            scope = .all
        }
        return openDetails(taskID: id)
    }
}
