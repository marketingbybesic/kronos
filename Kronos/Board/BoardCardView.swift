// Kronos/Board/BoardCardView.swift
// One Board card: the same KListRow shell (checkbox, selection, hover) every task row in the
// app uses, with a narrow trailing slot (priority, due, subtask progress) instead of
// ListRowView's full fixed-column set — a kanban column is already narrow, so cards need not
// align with each other the way list rows must align down a shared column.
import SwiftUI
import KronosCore

struct BoardCardView: View {
    @Bindable var model: AppModel
    let task: KTask
    let column: BoardColumn

    private var isSelected: Bool { model.selectedTaskID == task.id }

    var body: some View {
        KListRow(isSelected: isSelected, isDone: task.status == .done, isChecked: task.status == .done,
                 status: KTaskStatus(task.status),
                 accessibilityLabel: task.title,
                 accessibilityValue: String(localized: String.LocalizationValue(column.titleKey)),
                 onToggle: { ListCompletion.toggle(task, store: model.store, model: model) },
                 onSelect: { model.selectedTaskID = task.id }) {
            Text(task.title)
                .font(Typo.row)
                .foregroundStyle(Tok.textPrimary)
                .lineLimit(2)
        } trailing: {
            if task.priority != .none {
                PriorityGlyph(level: task.priority.rawValue, label: ViewOptionsMapper.priorityName(task.priority))
            }
            if let due = task.effectiveDue {
                Text(ListDueText.shown(due: due, original: task.originalDueDay).text)
                    .font(Typo.count)
                    .foregroundStyle(Tok.textSecondary)
            }
            if !task.orderedChildren.isEmpty {
                KSubtaskProgress(done: task.orderedChildren.filter { $0.status == .done }.count,
                                 total: task.orderedChildren.count)
            }
        }
        .onDrag {
            DragOut.provider(task: task)
        } preview: {
            DragLiftPreview(title: task.title, selectionCount: 1)
        }
        .uiTestAnchor("board.card.\(task.id.uuidString)")
    }
}
