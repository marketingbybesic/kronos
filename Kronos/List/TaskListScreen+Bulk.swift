// Kronos/List/TaskListScreen+Bulk.swift
// Multi-selection wiring for the list (TaskListScreen.swift and ListRowView.swift sit at the
// 500-line cap, so this lives in an extension): click modifiers, ⌘A / Esc, pruning, the
// bulk-aware grammar keys and the floating bar. The rules themselves are in ListSelection.swift
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
            rangeCursor = nil
        } else if flags.contains(.shift) {
            apply(ListSelection.range(to: id, from: selectionState(), rows: rows))
            rangeCursor = id   // ⇧↑/⇧↓ go on from the clicked end
        } else {
            model.selectedIDs = []
            model.selectedTaskID = id
            rangeCursor = nil
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
        ListLegendState.shared.hide()
        guard !Self.isTyping, !model.selectedIDs.isEmpty else { return .ignored }
        model.selectedIDs = []
        rangeCursor = nil
        return .handled
    }

    /// Keeps the set to rows that are still visible (called with the single-selection prune).
    func pruneBulk(_ ctx: ListContext) {
        guard !model.selectedIDs.isEmpty else { return }
        apply(ListSelection.pruned(selectionState(), rows: ctx.rows.map(\.id)))
    }

    /// A grammar key on the whole set (one undo step, one pill): T ⇧T H plan, 0-4 priority, S M L
    /// effort, W waiting, Y someday. D, P, B, F act on one task and are ignored here. Returns
    /// true when it consumed the key.
    func handleBulkAction(_ action: ListKeyAction) -> Bool {
        guard isMultiSelected else { return false }
        let today = Day.today()
        switch action {
        case .planToday: ListBulk.apply(.plan(today), model: model)
        case .planTomorrow: ListBulk.apply(.plan(today + 1), model: model)
        case .snooze: ListBulk.apply(.snooze, model: model)
        case .priority(let level): ListBulk.apply(.priority(KPriority(rawValue: level) ?? .none), model: model)
        case .effort(let size): ListBulk.apply(.effort(size.effort), model: model)
        case .waiting: ListBulk.apply(.toggleWaiting, model: model)
        case .someday: ListBulk.apply(.toggleSomeday, model: model)
        case .pickDue, .pickProject, .breakDown, .focusPin, .expandAll: return false
        }
        return true
    }

    // MARK: - Floating bar

    /// Bottom inset the rows keep while the bar is up: the bar's height, its distance from the
    /// window edge, and one gap, so no row ever sits behind it.
    var bulkBarClearance: CGFloat { Metrics.controlRegular + Space.x2 + Space.x8 + Space.x6 + Space.x3 }

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
