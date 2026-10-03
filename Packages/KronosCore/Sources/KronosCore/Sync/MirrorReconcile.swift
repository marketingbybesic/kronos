// `#Predicate` cannot follow optional relationships, so KTask carries scalar mirrors of them:
// `projectID`, `areaID`, `isProjectArchived` (of `project`) and `parentID` (of `parent`). Every
// store writer keeps them in step, but a sync delivers record references and scalar fields
// independently and out of order, so after an import the two sides can disagree and every
// filter on the scalar would lie. This pass re-derives the mirrors from the relationships:
// the relationships win.
//
// Rules:
//   - `project` set: projectID, areaID and isProjectArchived come from it;
//   - `project` nil: projectID nil, isProjectArchived false; areaID is left alone (a task can
//     sit directly in an area with no project, and then areaID is its own value);
//   - `parent` set: parentID from it, and the subtask carries its parent's project (one rule of
//     the hierarchy: a subtask lives where its parent lives);
//   - `parent` nil: parentID nil.
// Machine write: no undo step, `updatedAt` untouched (derived values are not an edit).

import Foundation
import SwiftData

@MainActor
public enum MirrorReconcile {

    /// Fix every task (or only `ids`), soft-deleted rows included. Returns how many rows changed.
    @discardableResult
    public static func run(in store: TaskStore, only ids: Set<UUID>? = nil) -> Int {
        let rows = store.allTasksIncludingDeleted().filter { ids?.contains($0.id) ?? true }
        var fixed = 0
        for t in rows where reconcile(t) { fixed += 1 }
        if fixed > 0 { store.saveContext() }
        return fixed
    }

    /// One row; true when anything changed.
    static func reconcile(_ t: KTask) -> Bool {
        var changed = false
        if let parent = t.parent {
            if t.parentID != parent.id { t.parentID = parent.id; changed = true }
            if t.project !== parent.project { t.project = parent.project; changed = true }
        } else if t.parentID != nil {
            t.parentID = nil; changed = true
        }
        if let p = t.project {
            if t.projectID != p.id { t.projectID = p.id; changed = true }
            if t.areaID != p.area?.id { t.areaID = p.area?.id; changed = true }
            if t.isProjectArchived != p.isArchived { t.isProjectArchived = p.isArchived; changed = true }
        } else {
            if t.projectID != nil { t.projectID = nil; changed = true }
            if t.isProjectArchived { t.isProjectArchived = false; changed = true }
            if let parent = t.parent, t.areaID != parent.areaID { t.areaID = parent.areaID; changed = true }
        }
        return changed
    }
}
