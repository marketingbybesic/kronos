// Part of TaskStore. The commit APIs for the two
// capture features. Both are ONE undo step regardless of how many rows they
// touch, via `groupedUndo` — Cmd-Z after accepting 12 proposed tasks removes
// all 12 in one keystroke, exactly like `RecurrenceSpawner`'s
// completion-plus-spawn and `clearDoneFromOrdo`'s multi-row sweep.
//
// Extensions in a separate file cannot see `private` members, so the undo
// plumbing these rely on (groupedUndo, appendIndex) is used through its
// public/internal surface only; nothing new needed to be widened for this.

import Foundation
import SwiftData

@MainActor
extension TaskStore {

    /// Commit accepted proposals as real tasks. REGISTERS UNDO (one step for
    /// the whole batch). Resolves `projectName` to an existing project by
    /// folded name — an unresolved name falls back to `defaultProject` rather
    /// than silently dropping the task's project — creates/reuses labels via
    /// `label(named:)`, and sets `firstMove`, priority, effort, due day and
    /// notes. Skips nothing on its own: the caller (the UI) decides which
    /// proposals to include by only passing the checked ones.
    @discardableResult
    public func createMany(_ proposals: [ProposedTask], defaultProject: KProject? = nil) -> [KTask] {
        guard !proposals.isEmpty else { return [] }
        var created: [KTask] = []
        groupedUndo("Create Tasks") {
            let existingProjects = allProjects(includeArchived: true)
            for proposal in proposals {
                let resolvedProject = proposal.projectName.flatMap { name in
                    existingProjects.first { KTextFold.fold($0.name) == KTextFold.fold(name) }
                } ?? defaultProject
                // Wave 15, 21b: a proposal with no due day used to hardcode `.todo`, which is
                // exactly the "open undated todo" bypass the migration exists to clean up after
                // — every OTHER creation path with an optional date (ListScopeDefaults.apply,
                // used by QuickAdd and MCP create_task) already sends an undated task straight
                // to `.someday`. Capture had its own copy of the same decision instead of
                // sharing it; mirror it here rather than adding a second funnel.
                let task = create(title: proposal.title, notes: proposal.notes ?? "",
                                  project: resolvedProject,
                                  status: proposal.dueDay != nil ? .todo : .someday,
                                  priority: proposal.priority, dueDay: proposal.dueDay)
                task.effort = proposal.effort
                task.firstMove = proposal.firstMove
                for name in proposal.labelNames {
                    let l = label(named: name)
                    addLabel(l, to: task.id)
                }
                created.append(task)
            }
        }
        return created
    }

    /// Append breakdown steps after a task's existing subtasks, never
    /// editing or reordering what is already there. REGISTERS UNDO (one step
    /// for the whole batch), via the same `addSubtask` each step already
    /// registers undo for individually — `groupedUndo` collapses them.
    public func addSubtasks(_ titles: [String], to id: UUID) {
        guard !titles.isEmpty else { return }
        groupedUndo("Add Subtasks") {
            for title in titles {
                addSubtask(id, title: title)
            }
        }
    }
}
