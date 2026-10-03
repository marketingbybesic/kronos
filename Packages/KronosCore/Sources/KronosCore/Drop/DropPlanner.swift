// KronosCore/Drop/DropPlanner.swift
// Maps a resolved drop position to the one store operation it stands for, and decides when
// the one-level rule is kept. Pure: the list commit code applies the command (store setParent / reorderChild), the table in
// DropZoneTests pins every mapping.
import Foundation

/// The operation a drop commits.
public enum DropCommand: Equatable, Sendable {
    /// Reorder a level-0 task; `before` nil moves it to the end.
    case moveTask(UUID, before: UUID?)
    /// A task becomes a child of `under`, landing before `before` (nil: at the end). Its own
    /// children follow it as siblings, so the hierarchy stays one level deep.
    case nestTask(UUID, under: UUID, before: UUID?)
    /// Reorder a step inside its own task; `before` nil moves it to the end.
    case reorderSubtask(UUID, before: UUID?)
    /// A step moves to another task, landing before `before` (nil: at the end).
    case moveSubtask(UUID, under: UUID, before: UUID?)
    /// A step becomes a level-0 task, landing before `before` (nil: at the end).
    case promoteSubtask(UUID, before: UUID?)
    /// A new task from an external item, landing before `before` (nil: at the end).
    case createTask(before: UUID?)
    /// An external item is attached to the row.
    case attach(rowID: UUID, isSubtask: Bool)
    case none
}

public enum DropPlanner {
    public static func command(for resolution: DropResolution, subject: DropSubject) -> DropCommand {
        switch resolution.zone {
        case .none:
            return .none
        case .insertAbove, .insertBelow:
            switch subject.source {
            case .task:
                guard let id = subject.id else { return .none }
                return .moveTask(id, before: resolution.before)
            case .subtask:
                guard let id = subject.id, let parent = subject.parentID else { return .none }
                if resolution.insertsAmongSubtasks {
                    return parent == resolution.taskID
                        ? .reorderSubtask(id, before: resolution.before)
                        : .moveSubtask(id, under: resolution.taskID, before: resolution.before)
                }
                return .promoteSubtask(id, before: resolution.before)
            case .external:
                return .createTask(before: resolution.before)
            }
        case .nest:
            guard subject.source == .task, let id = subject.id else { return .none }
            // Onto a child row the task becomes that child's sibling under the same parent (never a
            // grandchild): `resolution.taskID` is always the top-level parent of the row.
            return .nestTask(id, under: resolution.taskID, before: resolution.before)
        case .moveUnder:
            guard subject.source == .subtask, let id = subject.id else { return .none }
            return .moveSubtask(id, under: resolution.taskID, before: resolution.before)
        case .attachLink:
            guard subject.source == .external else { return .none }
            return .attach(rowID: resolution.rowID, isSubtask: resolution.rowKind == .subtask)
        }
    }
}
