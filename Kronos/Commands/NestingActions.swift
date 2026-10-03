// Kronos/Commands/NestingActions.swift
// What Cmd-] and Cmd-[ do. Both are invoked from the Task menu items (NestingCommands.swift),
// which the OptionChordMonitor also fires for the layouts where SwiftUI's own key equivalent
// cannot. The menu items are never `.disabled(...)`: a Commands body is evaluated once, so a
// disabled state could never follow the selection. The action decides instead, and says why
// when it refuses (a notice pill; nothing is changed and no undo step is pushed).
import AppKit
import KronosCore

@MainActor
enum NestingActions {

    /// Cmd-]: the selected task becomes a subtask of the task directly above it in the list
    /// as the user sees it (current scope, sort, filter, search).
    static func nestSelected(model: AppModel) {
        guard canAct(model) else { return }
        guard model.selectedIDs.isEmpty, let id = model.selectedTaskID, let task = model.store.task(id) else {
            notice(String(localized: "list.nest.err.select")); return
        }
        // A focused subtask can't go one level deeper (one level only).
        if SubtaskFocus.current(in: model) != nil || task.isSubtask {
            notice(String(localized: "list.nest.err.subtask")); return
        }
        let rows = ListContext(model: model).rows
        let title = task.title
        let parentTitle = KeyboardNesting.taskAbove(id, in: rows.map(\.id)).flatMap { above in rows.first { $0.id == above }?.title }

        switch model.store.nestUnderTaskAbove(id, rows: rows.map(\.id)) {
        case .nested(let parentID):
            model.selectedTaskID = parentID
            model.selectedIDs = []
            model.commit(String(format: String(localized: "undo.nested.name"), title, parentTitle ?? ""))
        case .noTaskAbove:
            notice(String(localized: "list.nest.err.noabove"))
        case .refused(let reason):
            notice(message(for: reason))
        }
    }

    /// Cmd-[: the focused subtask (middle list row or inspector step) becomes a standalone task
    /// right after its parent.
    static func promoteFocused(model: AppModel) {
        guard canAct(model) else { return }
        guard let subID = targetSubtask(model), let sub = model.store.subtaskRef(subID) else {
            notice(String(localized: "list.unnest.err.select")); return
        }
        let title = sub.title
        guard let task = model.store.promoteSubtaskAfterParent(subID) else {
            notice(String(localized: "list.nest.err.gone")); return
        }
        SubtaskFocus.clear()
        model.selectedTaskID = task.id
        model.selectedIDs = []
        model.commit(String(format: String(localized: "undo.unnested.name"), title))
    }

    /// The subtask Cmd-[ acts on: the focused row or inspector step, else the subtask the
    /// inspector is showing for the selected task.
    private static func targetSubtask(_ model: AppModel) -> UUID? {
        if let focused = SubtaskFocus.current(in: model) { return focused }
        guard let shown = model.inspectedSubtaskID, let ref = model.store.subtaskRef(shown),
              ref.parentID != nil, ref.parentID == model.selectedTaskID else { return nil }
        return shown
    }

    /// The localized text for a refusal. `TaskNestError.errorDescription` is English only, so the
    /// UI never shows it.
    static func message(for error: TaskNestError) -> String {
        switch error {
        case .parentIsSubtask: return String(localized: "list.nest.err.subtask")
        case .sameTask: return String(localized: "list.nest.err.self")
        case .taskNotFound, .parentNotFound: return String(localized: "list.nest.err.gone")
        }
    }

    /// Not while a text field owns the keyboard (the chord belongs to the field), not under an
    /// overlay, only when the main window is key (not Settings or the quick-add panel).
    private static func canAct(_ model: AppModel) -> Bool {
        guard !model.isAnyOverlayOpen, !TaskListScreen.isTyping else { return false }
        // Same test OptionChordMonitor uses for "the main Kronos window".
        guard let key = NSApp.keyWindow ?? NSApp.mainWindow else { return true }
        return !(key is NSPanel) && key.title == "Kronos"
    }

    private static func notice(_ text: String) {
        UndoToastCenter.shared.showNotice(text)
    }
}
