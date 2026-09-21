// Kronos/Detail/FirstMoveLogic.swift
// Pure decision for the inspector's "First move" section (gate G3). A task with an open
// subtask shows THAT subtask, read-only, as the first move (reordering subtasks changes it
// automatically because it's just the next-open lookup, never a copy) — a task with subtasks
// needs no separate first-move field of its own. Only a task with none of its own — the
// editable field — stores something in `firstMove` itself.
// Foundation only (no SwiftUI/KronosCore): scripts/firstmove-selftest.swift compiles this
// file standalone against a hand-written table so the mirrored logic can never drift from
// the version actually shipping in InspectorScreen.
import Foundation

/// What the First move section should render, decided purely from primitives (never from a
/// live `KTask`, so this stays compilable without SwiftData) — call with
/// `task.nextOpenSubtask?.title` and `task.firstMove`.
public enum FirstMoveDisplay: Equatable {
    /// Read-only: the task has an open subtask, shown as its de-facto first move.
    case fromSubtask(title: String)
    /// Editable: no open subtask, so `firstMove` (possibly empty/nil) is a real field.
    case editable(text: String?)
}

public enum FirstMoveLogic {
    /// - Parameters:
    ///   - nextOpenSubtaskTitle: `task.nextOpenSubtask?.title` — nil when there is no open
    ///     subtask (none exist, or all are done).
    ///   - firstMove: `task.firstMove` as stored, untouched.
    public static func display(nextOpenSubtaskTitle: String?, firstMove: String?) -> FirstMoveDisplay {
        if let title = nextOpenSubtaskTitle { return .fromSubtask(title: title) }
        return .editable(text: firstMove)
    }
}
