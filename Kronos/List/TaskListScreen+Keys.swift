// Kronos/List/TaskListScreen+Keys.swift
// The list's keyboard: arrows (⇧ extends the range), Space, Delete, Return, and the single-key
// grammar (ListKeyGrammar.swift: T ⇧T D P H 0-4 S M L B W Y F E). Every key is inert while a
// text field types (`isTyping`). A grammar key acts on the whole multi-selection when 2+ rows
// are selected (one undo step), else on the selected row; every write raises the undo pill.
import SwiftUI
import AppKit
import KronosCore

extension TaskListScreen {
    /// True while a text field owns the keyboard. The list container reports itself focused even
    /// when focus is in the inline field INSIDE it, so a FocusState check let space, Return, o, h, f
    /// and 0-4 be eaten while typing (the live UI test typed "Buy oat milk" and got "Buyatmilk").
    static var isTyping: Bool {
        // Not only keyWindow: it is nil for a moment whenever the app is not frontmost, and the
        // keys would be eaten again exactly then.
        (NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible })?.firstResponder is NSTextView
    }

    /// Current bindings of every grammar key (override or default), by registry id.
    static func grammarBindings() -> [String: HotkeyBinding] {
        var out: [String: HotkeyBinding] = [:]
        for (id, _) in ListKeyGrammar.rebindable { out[id] = HotkeyRegistry.current(for: id) }
        return out
    }

    // MARK: Arrows

    func moveSelection(_ delta: Int, _ ctx: ListContext) {
        guard !ctx.rows.isEmpty else { return }
        model.selectedIDs = []   // arrows go back to a single selection
        rangeCursor = nil
        guard let current = model.selectedTaskID, let i = ctx.rows.firstIndex(where: { $0.id == current }) else {
            model.selectedTaskID = ctx.rows.first?.id
            return
        }
        let next = max(0, min(ctx.rows.count - 1, i + delta))
        model.selectedTaskID = ctx.rows[next].id
    }

    /// ⇧↑/⇧↓: the range from the anchor (the selected row) to a moving end, one row per press.
    func extendSelection(_ delta: Int, _ ctx: ListContext) {
        let rows = ctx.rows.map(\.id)
        let state = ListSelectionState(anchor: model.selectedTaskID, ids: model.selectedIDs)
        let result = ListSelection.extend(by: delta, from: state, cursor: rangeCursor, rows: rows)
        model.selectedTaskID = result.state.anchor
        model.selectedIDs = result.state.ids
        rangeCursor = result.cursor
        listFocused = true
    }

    // MARK: Space, Delete, Return

    func toggleSelected(_ ctx: ListContext) {
        if isMultiSelected { ListBulk.apply(.toggleDone, model: model); return }
        guard let id = model.selectedTaskID, let task = ctx.rows.first(where: { $0.id == id }) else { return }
        ListCompletion.toggle(task, store: model.store, model: model)
    }

    func deleteSelected(_ ctx: ListContext) {
        if isMultiSelected { ListBulk.apply(.delete, model: model); return }
        guard let id = model.selectedTaskID, let task = ctx.rows.first(where: { $0.id == id }) else { return }
        let next = ListCompletion.neighbourToSelect(after: id, model: model)
        model.store.softDelete(task.id)
        if let next { model.selectedTaskID = next }
        model.commit(String(format: String(localized: "undo.deleted.name"), task.title))
    }

    /// Return opens the selected row in the inspector and puts the keyboard in its title, so
    /// typing renames the task; Esc there comes back to the list (InspectorScreen posts
    /// `kronosFocusListRequested`). A focused child row opens its own details.
    func selectAndOpen(_ ctx: ListContext) {
        // A focused child row of the selected task: Return opens its details. The key reaches the
        // list when the row itself did not take it (the list container keeps the key focus).
        if let child = SubtaskFocus.current(in: model) {
            model.openDetails(taskID: child)
            return
        }
        guard let id = model.selectedTaskID, ctx.rows.contains(where: { $0.id == id }) else { return }
        model.openDetails(taskID: id)
        // Next turn of the run loop: the inspector has re-rendered on the task by then.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: UIRequests.focusInspectorTitle, object: nil, userInfo: ["taskID": id])
        }
    }

    // MARK: Grammar

    /// One grammar key press. Returns false when the key means nothing here (no row selected, a
    /// chord), so the press falls through.
    func handleGrammarKey(_ press: KeyPress, _ ctx: ListContext) -> Bool {
        guard let action = ListKeyGrammar.action(characters: press.characters,
                                                 shift: press.modifiers.contains(.shift),
                                                 command: press.modifiers.contains(.command),
                                                 option: press.modifiers.contains(.option),
                                                 control: press.modifiers.contains(.control),
                                                 bindings: Self.grammarBindings()) else { return false }
        if action == .expandAll {
            allSubtasksExpanded.toggle()
            NotificationCenter.default.post(name: .kronosExpandAllSubtasks, object: allSubtasksExpanded)
            return true
        }
        if isMultiSelected { return handleBulkAction(action) }
        guard let id = model.selectedTaskID, let task = ctx.rows.first(where: { $0.id == id }) else { return false }
        perform(action, on: task)
        return true
    }

    /// Runs one grammar action on one task (TaskListScreen+Actions.swift holds the writes).
    func perform(_ action: ListKeyAction, on task: KTask) {
        switch action {
        case .planToday: plan(task, daysFromToday: 0)
        case .planTomorrow: plan(task, daysFromToday: 1)
        case .snooze: snoozeTask(task)
        case .pickDue: ListRowRequests.post(ListRowRequests.pickDue, taskID: task.id)
        case .pickProject: ListRowRequests.post(ListRowRequests.pickProject, taskID: task.id)
        case .priority(let level): setPriority(task, KPriority(rawValue: level) ?? .none)
        case .effort(let size): setEffort(task, size)
        case .breakDown: breakDown(task)
        case .waiting: toggleWaiting(task)
        case .someday: toggleSomeday(task)
        case .focusPin: toggleFocusPin(task)
        case .expandAll: break
        }
    }
}
