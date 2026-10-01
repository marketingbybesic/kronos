// Kronos/List/TaskListScreen+Bulk.swift
// Multi-selection wiring for the list (TaskListScreen.swift and ListRowView.swift sit at the
// 500-line cap, so this lives in an extension): click modifiers, ⌘A / Esc, pruning, the
// bulk-aware key shortcuts and the floating bar. The rules themselves are in ListSelection.swift
// (pure) and ListBulkActions.swift (one undo step per action).
import SwiftUI
import KronosCore

extension TaskListScreen {
    /// True while 2+ rows are selected: the bar shows and the list keys act on the whole set.
    var isMultiSelected: Bool { model.selectedIDs.count > 1 }

    /// Row look for both single and multi selection: the one existing selection background.
    func isRowSelected(_ id: UUID) -> Bool {
        model.selectedTaskID == id || model.selectedIDs.contains(id)
    }

    private func selectionState() -> ListSelectionState {
        ListSelectionState(anchor: model.selectedTaskID, ids: model.selectedIDs)
    }

    private func apply(_ s: ListSelectionState) {
        model.selectedTaskID = s.anchor
        model.selectedIDs = s.ids
    }

    /// ⌘-click toggles the row, ⇧-click selects the range from the anchor, a plain click is the
    /// old single selection (and drops any multi-selection).
    func handleRowClick(_ id: UUID, _ ctx: ListContext) {
        let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        let rows = ctx.rows.map(\.id)
        if flags.contains(.command) {
            apply(ListSelection.toggle(id, from: selectionState(), rows: rows))
        } else if flags.contains(.shift) {
            apply(ListSelection.range(to: id, from: selectionState(), rows: rows))
        } else {
            model.selectedIDs = []
            model.selectedTaskID = id
        }
        listFocused = true
    }

    /// ⌘A: every visible row. Ignored while a text field types, so the field keeps its own ⌘A.
    func handleSelectAll(_ press: KeyPress, _ ctx: ListContext) -> KeyPress.Result {
        guard press.modifiers == .command, press.characters.lowercased() == "a" else { return .ignored }
        guard let s = ListSelection.selectAll(from: selectionState(), rows: ctx.rows.map(\.id), isTyping: Self.isTyping) else { return .ignored }
        apply(s)
        return .handled
    }

    /// Esc clears the multi-selection (the anchor stays selected). Passes through otherwise.
    func handleEscape() -> KeyPress.Result {
        guard !Self.isTyping, !model.selectedIDs.isEmpty else { return .ignored }
        model.selectedIDs = []
        return .handled
    }

    /// Keeps the set to rows that are still visible (called with the single-selection prune).
    func pruneBulk(_ ctx: ListContext) {
        guard !model.selectedIDs.isEmpty else { return }
        apply(ListSelection.pruned(selectionState(), rows: ctx.rows.map(\.id)))
    }

    /// Single-key actions on the whole set: 0-4 / o priority and the rebindable snooze key.
    /// Returns true when it consumed the key.
    func handleBulkCharacter(_ characters: String) -> Bool {
        guard isMultiSelected else { return false }
        switch characters.lowercased() {
        case Self.listKey("list.snooze"): ListBulk.apply(.snooze, model: model)
        case "0", "o": ListBulk.apply(.priority(.none), model: model)
        case "1": ListBulk.apply(.priority(.low), model: model)
        case "2": ListBulk.apply(.priority(.medium), model: model)
        case "3": ListBulk.apply(.priority(.high), model: model)
        case "4": ListBulk.apply(.priority(.urgent), model: model)
        default: return false
        }
        return true
    }

    // MARK: - Floating bar

    /// Bottom-centre of the list, only while 2+ rows are selected. Sits above the undo pill
    /// (which owns the very bottom edge of the window) so the two never overlap.
    @ViewBuilder
    var bulkBarOverlay: some View {
        VStack {
            Spacer()
            if isMultiSelected {
                KBulkBar(label: ListBulk.selected(model.selectedIDs.count),
                         closeLabel: String(localized: "list.bulk.close"),
                         onClose: { model.selectedIDs = [] },
                         controls: { BulkActionControls(model: model) },
                         trailing: { BulkDeleteButton(model: model) })
                    .padding(.bottom, Space.x8 + Space.x6)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(Motion.reduceMotion ? nil : Motion.curve(Motion.fast), value: isMultiSelected)
    }
}
