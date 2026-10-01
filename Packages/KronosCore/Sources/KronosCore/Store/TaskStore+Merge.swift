// Part of TaskStore. "Merge tasks": a new entry whose title matches an open task is folded INTO
// that task instead of being refused or duplicated. Nothing the existing task already has is
// overwritten or dropped: new subtasks are appended (a subtask with the same title is skipped),
// new notes are appended below the old ones, new labels are added, and a field the existing task
// has not set (due day, priority, effort, project, first move) is filled from the new entry.
// One undo step for the whole merge.

import Foundation
import SwiftData

public struct TaskMergeOutcome: Equatable, Sendable {
    public var targetID: UUID
    public var subtasksAdded: Int
    public var notesAppended: Bool
    public var labelsAdded: Int
    /// Fields that were empty on the existing task and got the new entry's value.
    public var filled: [String]
    /// Nothing changed (the new entry carried nothing the task did not already have).
    public var isNoOp: Bool { subtasksAdded == 0 && !notesAppended && labelsAdded == 0 && filled.isEmpty }
}

@MainActor
extension TaskStore {

    /// The open task a new entry with this title would duplicate: same folded title, not done,
    /// canceled or deleted. Several matches resolve to the oldest, the one the person made first.
    public func openTask(matchingTitle title: String) -> KTask? {
        let key = KTextFold.fold(title.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !key.isEmpty else { return nil }
        return allTasks()
            .filter { KStatus.open.contains($0.status) && KTextFold.fold($0.title.trimmingCharacters(in: .whitespacesAndNewlines)) == key }
            .min { $0.createdAt < $1.createdAt }
    }

    /// Folds `proposal` (plus its `subtasks`, which travel beside it in the capture review) into
    /// the task `id`. REGISTERS UNDO (one step). Returns nil when the task is gone.
    @discardableResult
    public func mergeProposal(_ proposal: ProposedTask, subtasks: [String], into id: UUID,
                              defaultProject: KProject? = nil) -> TaskMergeOutcome? {
        guard let target = task(id) else { return nil }
        var outcome = TaskMergeOutcome(targetID: id, subtasksAdded: 0, notesAppended: false, labelsAdded: 0, filled: [])
        groupedUndo("Merge Tasks") {
            // Subtasks: only titles the task does not already have, each once.
            var seen = Set(target.orderedSubtasks.map { KTextFold.fold($0.title) })
            var fresh: [String] = []
            for raw in subtasks {
                let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, seen.insert(KTextFold.fold(title)).inserted else { continue }
                fresh.append(title)
            }
            addSubtasks(fresh, to: id)
            outcome.subtasksAdded = fresh.count

            // Labels: union.
            let have = Set((target.labels ?? []).map { KTextFold.fold($0.name) })
            for name in proposal.labelNames where !have.contains(KTextFold.fold(name)) {
                addLabel(label(named: name), to: id)
                outcome.labelsAdded += 1
            }

            // Notes: appended below, never replacing, and not repeated when already contained.
            let newNotes = (proposal.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let oldNotes = target.notes
            let alreadyThere = KTextFold.fold(oldNotes).contains(KTextFold.fold(newNotes))
            let projects = allProjects(includeArchived: true)
            let proposedProject = proposal.projectName.flatMap { name in
                projects.first { KTextFold.fold($0.name) == KTextFold.fold(name) }
            } ?? defaultProject

            var filled: [String] = []
            update(id) { t in
                if !newNotes.isEmpty, !alreadyThere {
                    t.notes = oldNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? newNotes : oldNotes + "\n\n" + newNotes
                    outcome.notesAppended = true
                }
                if t.dueDay == nil, let day = proposal.dueDay { t.dueDay = day; filled.append("due") }
                if t.priority == .none, proposal.priority != .none { t.priority = proposal.priority; filled.append("priority") }
                if t.effort == .none, proposal.effort != .none { t.effort = proposal.effort; filled.append("effort") }
                if t.project == nil, let p = proposedProject { t.project = p; filled.append("project") }
                if (t.firstMove ?? "").isEmpty, let move = proposal.firstMove, !move.isEmpty { t.firstMove = move; filled.append("firstMove") }
            }
            outcome.filled = filled
        }
        return outcome
    }
}
