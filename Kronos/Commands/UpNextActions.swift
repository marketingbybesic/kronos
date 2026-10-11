// Kronos/Commands/UpNextActions.swift
// What ⌘⇧O (append) and ⌥⌘⇧O (push to top) do: send the task-list selection to Up next (the
// ORDO queue). Declared as Commands shortcuts in KronosApp.swift, so — unlike Cmd-]/Cmd-[
// (NestingActions.swift) — both fire even while a text field is first responder
// (the internal notes:50 names ⌘⇧O explicitly among the chords that must). The multi-selection
// (2+ rows, interaction.md §1.1) goes through ListBulk.apply for one undo step; otherwise the
// highlighted row acts alone, same write as the row's own "Send to Up next" context-menu item
// (TaskContextMenu.swift).
import AppKit
import KronosCore

@MainActor
enum UpNextActions {
    static func send(top: Bool, model: AppModel) {
        guard canAct(model) else { return }
        if model.selectedIDs.count > 1 {
            ListBulk.apply(.sendToUpNext(top: top), model: model)
            return
        }
        guard let id = model.selectedTaskID, let task = model.store.task(id) else {
            UndoToastCenter.shared.showNotice(String(localized: "list.sendtoupnext.err.select"))
            return
        }
        // The ORDO queue lists top-level tasks only (TaskStore+Mutations.swift's
        // sendToOrdo(_:top:) silently no-ops on a subtask) — same refusal
        // TaskContextMenu.swift hides its Send to Up next items for, but the hotkey has no
        // menu to hide, so it must say why instead of faking a pill + undo step that would
        // really undo the PREVIOUS action.
        guard !task.isSubtask else {
            UndoToastCenter.shared.showNotice(String(localized: "list.sendtoupnext.err.subtask"))
            return
        }
        model.store.sendToOrdo(id, top: top)
        let message = top ? String(format: String(localized: "undo.sendtoupnexttop.name"), task.title)
                           : String(format: String(localized: "undo.sendtoupnext.name"), task.title)
        model.commit(message)
    }

    /// Not under an overlay — the list beneath a scrim never moves silently, the same rule
    /// NestingActions.swift applies to Cmd-]/Cmd-[ — and only while the main Kronos window is
    /// key (not Settings or the quick-add panel), the same test `OptionChordMonitor` uses.
    private static func canAct(_ model: AppModel) -> Bool {
        guard !model.isAnyOverlayOpen else { return false }
        guard let key = NSApp.keyWindow ?? NSApp.mainWindow else { return true }
        return !(key is NSPanel) && key.title == "Kronos"
    }
}
