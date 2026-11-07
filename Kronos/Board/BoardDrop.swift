// Kronos/Board/BoardDrop.swift
// What a Board column accepts: a task row dragged from anywhere in the app (the list, another
// column) sets that task's status to the column it lands on — the existing store calls, one
// undo step, the usual pill. Reads the drag pasteboard synchronously, the same way the
// sidebar's own project-row drop does (Sidebar/SidebarTaskDrop.swift) — this is Board's exact
// counterpart to that file, down to the `NSPasteboard(name: .drag)` read.
//
// `BoardDrop.move` is also what `BoardScreen`'s `[`/`]` keys call, so a drag and a key can never
// disagree about what moving a card into a column does.
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import KronosCore

@MainActor
enum BoardDrop {
    /// Moves `taskID` into `column`. False when nothing happened (refused, already there, or the
    /// task is gone) — the caller never raises a pill or an undo step on false.
    @discardableResult
    static func move(_ taskID: UUID, to column: BoardColumn, model: AppModel, today: Int) -> Bool {
        guard let task = model.store.task(taskID) else { return false }
        guard task.reviewRaw != ReviewState.awaitingCheck else {
            UndoToastCenter.shared.showNotice(String(localized: "board.pill.reviewlocked"))
            return false
        }
        guard column != .review, BoardColumn.of(task, today: today) != column else { return false }

        switch column {
        case .doneToday:
            // `ListCompletion.toggle` already does exactly "complete, unless it waits on an open
            // task" (the shell's own "Finish <B> first" card) plus the usual "Done. Next:" pill —
            // the same path every other completion in the app takes.
            ListCompletion.toggle(task, store: model.store, model: model)
            return true
        case .todo, .inProgress, .waiting:
            let target: KStatus = column == .todo ? .todo : (column == .inProgress ? .inProgress : .waiting)
            model.store.groupedUndo(undoName(column)) {
                if task.status == .done { model.store.reopen(taskID) }
                if column == .waiting {
                    model.store.setWaiting(taskID, true)
                } else if model.store.task(taskID)?.status != target {
                    model.store.setStatus(taskID, target)
                }
            }
            model.commit(pillMessage(column, title: task.title))
            return true
        case .review:
            return false
        }
    }

    /// Plain English undo-stack name (never shown; matches the style of existing `groupedUndo` call sites).
    private static func undoName(_ column: BoardColumn) -> String {
        switch column {
        case .todo: return "Move to To do"
        case .inProgress: return "Move to In progress"
        case .waiting: return "Move to Waiting"
        case .doneToday, .review: return "Move"
        }
    }

    private static func pillMessage(_ column: BoardColumn, title: String) -> String {
        switch column {
        case .todo: return String(format: String(localized: "board.pill.movedtodo"), title)
        case .inProgress: return String(format: String(localized: "board.pill.movedinprogress"), title)
        // Reuses the List key W pill verbatim: the task really is waiting and really does return
        // to Today in three days, regardless of whether a key or a Board drop put it there.
        case .waiting: return String(format: String(localized: "list.pill.waiting"), title)
        case .doneToday, .review: return ""
        }
    }
}

/// One Board column's drop target. `isTargeted` is a `Binding` so the column view can draw the
/// hover outline without this delegate holding any `@State` of its own.
struct BoardColumnDropDelegate: DropDelegate {
    static let types: [UTType] = [.plainText]

    let column: BoardColumn
    let model: AppModel
    let today: Int
    @Binding var isTargeted: BoardColumn?

    private var pasteboard: NSPasteboard { NSPasteboard(name: .drag) }

    private func draggedTaskID() -> UUID? {
        guard case .task(let id) = DropZonePayloadReader.read(pasteboard) else { return nil }
        return id
    }

    func validateDrop(info: DropInfo) -> Bool { column != .review && draggedTaskID() != nil }

    func dropEntered(info: DropInfo) {
        if validateDrop(info: info) { isTargeted = column }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: validateDrop(info: info) ? .move : .forbidden)
    }

    func dropExited(info: DropInfo) {
        if isTargeted == column { isTargeted = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = nil
        guard let id = draggedTaskID() else { return false }
        return BoardDrop.move(id, to: column, model: model, today: today)
    }
}
