// Kronos/Palette/PaletteCommit.swift
// The one place a palette command writes the store on the user's behalf: it applies the write,
// refreshes the UI and raises the shell's undo pill, so a palette action always answers "did
// that happen?" the same way a key or a menu item does.
import Foundation
import AppKit
import KronosCore

@MainActor
enum PaletteCommit {
    /// Runs `write` (store calls that make one undo step), then refreshes and shows `message`.
    static func run(_ model: AppModel, message: String? = nil, _ write: () -> Void) {
        write()
        model.didMutate()
        if let message { UndoToastCenter.shared.show(message) }
    }

    /// Formats a catalog pattern. Every call site passes a literal key, so the string-key lint sees it.
    static func text(_ pattern: String, _ args: CVarArg...) -> String {
        String(format: pattern, arguments: args)
    }

    /// Puts a task's `kronos://` link on the pasteboard (as URL and as text) and says so.
    /// Nothing in the store changes, so nothing is pushed to undo.
    static func copyLink(_ id: UUID, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(TaskLink.string(for: id), forType: .URL)
        pasteboard.setString(TaskLink.string(for: id), forType: .string)
        UndoToastCenter.shared.showNotice(String(localized: "palette.notice.linkcopied"))
    }

    /// A copy of a top-level task with its steps, selected afterwards. One undo step.
    /// Done tasks come back open; nothing else about the copy is special.
    @discardableResult
    static func duplicate(_ id: UUID, model: AppModel) -> KTask? {
        let store = model.store
        guard let source = store.task(id), !source.isSubtask else { return nil }
        var copy: KTask?
        store.groupedUndo("palette.duplicate") {
            let made = store.create(title: source.title, notes: source.notes, project: source.project,
                                    status: source.status == .done ? .todo : source.status,
                                    priority: source.priority, dueDay: source.dueDay)
            store.update(made.id) {
                $0.effortRaw = source.effortRaw
                $0.depthRaw = source.depthRaw
                $0.estimateMinutes = source.estimateMinutes
                $0.dread = source.dread
                $0.firstMove = source.firstMove
                $0.recurrenceRule = source.recurrenceRule
                $0.labels = source.labels
            }
            for step in store.children(of: id) {
                _ = store.addChild(to: made.id, title: step.title, dueDay: step.dueDay, priority: step.priority)
            }
            copy = made
        }
        guard let copy else { return nil }
        model.selectedTaskID = copy.id
        model.didMutate()
        UndoToastCenter.shared.show(text(String(localized: "palette.undo.duplicated"), source.title))
        return copy
    }
}
