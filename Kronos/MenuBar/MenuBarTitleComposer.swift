// Kronos/MenuBar/MenuBarTitleComposer.swift
// Pure composition + truncation for the status item's title. Kept apart from
// MenuBarOrdoController (AppKit/NSStatusItem) and KMenuBarOrdoLabel (SwiftUI/design-system)
// so scripts/menubar-hit-selftest.swift can prove it without either dependency.
//
// When both are shown, the subtask (child) leads, the task (parent) follows, separated by
// " · ". No subtasks -> task only, regardless of mode (there is nothing else to show).
// Truncation is always TAIL, and the PARENT part (the task) truncates before the subtask.
import Foundation

enum MenuBarTitleComposer {
    /// nil `subtask` means the task itself has no open subtask — every mode then falls back
    /// to the task alone, since there is nothing to compose.
    static func compose(task: String, subtask: String?, mode: MenuBarTitleMode, width: MenuBarWidth) -> String {
        compose(task: task, subtask: subtask, mode: mode, maxChars: width.maxChars)
    }

    /// The status item fits the title to a width in POINTS; it searches this character budget.
    static func compose(task: String, subtask: String?, mode: MenuBarTitleMode, maxChars: Int) -> String {
        let parts = selectedParts(task: task, subtask: subtask, mode: mode)
        let joined = parts.joined(separator: " · ")
        return truncate(joined, task: parts.task, subtask: parts.subtask, taskFirst: parts.taskFirst, maxChars: maxChars)
    }

    private struct Parts {
        let task: String?
        let subtask: String?
        var taskFirst = false
        /// In display order: subtask first by default, task first when "task, then subtask"
        /// is picked (that mode used to be ignored here).
        var joined: [String] { (taskFirst ? [task, subtask] : [subtask, task]).compactMap { $0 } }
        func joined(separator: String) -> String { joined.joined(separator: separator) }
    }

    private static func selectedParts(task: String, subtask: String?, mode: MenuBarTitleMode) -> Parts {
        guard let subtask, !subtask.isEmpty else { return Parts(task: task, subtask: nil) }
        switch mode {
        case .subtaskThenTask: return Parts(task: task, subtask: subtask)
        case .taskThenSubtask: return Parts(task: task, subtask: subtask, taskFirst: true)
        case .subtaskOnly: return Parts(task: nil, subtask: subtask)
        case .taskOnly: return Parts(task: task, subtask: nil)
        }
    }

    /// Shrinks the TASK (parent) first, down to nothing, before the subtask loses a single
    /// character — matching "the PARENT part truncates before the subtask part". Truncation
    /// is always at the tail (an ellipsis replaces the dropped end), never the head or middle.
    private static func truncate(_ joined: String, task: String?, subtask: String?, taskFirst: Bool = false,
                                 maxChars: Int) -> String {
        guard joined.count > maxChars, maxChars > 1 else { return joined }
        guard let task, let subtask else {
            // A single part over budget: plain tail truncation.
            return String(joined.prefix(maxChars - 1)) + "…"
        }
        let separator = " · "
        let fixed = subtask.count + separator.count
        let taskBudget = maxChars - fixed
        if taskBudget >= 1 {
            let shortTask = task.count > taskBudget ? String(task.prefix(taskBudget - 1)) + "…" : task
            return taskFirst ? shortTask + separator + subtask : subtask + separator + shortTask
        }
        // Even the subtask alone (plus separator) doesn't fit: drop the task entirely and
        // tail-truncate the subtask against the full budget.
        return subtask.count > maxChars ? String(subtask.prefix(maxChars - 1)) + "…" : subtask
    }
}
