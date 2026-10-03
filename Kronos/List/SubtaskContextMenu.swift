// Kronos/List/SubtaskContextMenu.swift — attaches the child task's context menu to a subtask
// row, in the middle list (ListRowView.subtaskRow) and in the inspector's steps list. The menu
// itself is `TaskMenu.nodes` (TaskContextMenu.swift), shared with top-level task rows.
import SwiftUI
import AppKit
import KronosCore

// MARK: - Hooks

extension AppModel {
    /// Opens the inspector in child mode for `sub` (see `openDetails(taskID:)`).
    func openSubtaskDetails(_ sub: KTask) { openDetails(taskID: sub.id) }
}

// MARK: - Attachment (owns the "Pick…" popover)

private struct SubtaskMenuModifier: ViewModifier {
    let subtask: KTask
    let model: AppModel
    let parent: KTask
    /// "subrow" (middle list) or "step" (inspector): one subtask can show in both at once.
    let place: String
    @State private var pickingDue = false

    func body(content: Content) -> some View {
        content
            .kContextMenu(id: "\(place).\(subtask.id.uuidString)") {
                TaskMenu.nodes(task: subtask, model: model, pickDue: { pickingDue = true }, onSelect: {})
            }
            .popover(isPresented: $pickingDue, arrowEdge: .bottom) {
                SubtaskMenuDuePopover(subtask: subtask, model: model) { pickingDue = false }
            }
    }
}

/// Pick… on a subtask: the same date field the task row uses (typed date, Today, Tomorrow,
/// Next week, Clear), one write and one pill.
private struct SubtaskMenuDuePopover: View {
    let subtask: KTask
    let model: AppModel
    let close: () -> Void

    var body: some View {
        ListDueField(current: subtask.dueDay) { day in
            close()
            guard subtask.dueDay != day else { return }
            model.store.setDue(subtask.id, day: day)
            model.commit(ListPills.due(day, title: subtask.title))
        }
    }
}

extension View {
    /// The subtask context menu. `place` is "subrow" in the middle list, "step" in the inspector.
    func kSubtaskContextMenu(_ subtask: KTask, parent: KTask, model: AppModel, place: String) -> some View {
        modifier(SubtaskMenuModifier(subtask: subtask, model: model, parent: parent, place: place))
    }
}
