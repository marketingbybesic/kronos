// Kronos/Board/BoardKeyActions.swift
// Kronos v1.2 Phase 2 slice F2 follow-up: `[`/`]` move the selected card one column, factored
// out so BOTH the normal `.onKeyPress` path (BoardScreen.swift) and BoardKeyMonitor.swift's
// local-event-monitor fallback call the exact same write — one path, never two to drift. Same
// shape as Kronos/List/AgentKeyActions.swift.
import KronosCore

@MainActor
enum BoardKeyActions {
    /// `[` / `]`: move the selected card one column left or right, through
    /// `BoardColumn.movableOrder` — the same mutation `BoardDrop.move` performs for a drag, so
    /// a key and a drop can never disagree about what "one column over" means. A card sitting in
    /// Review refuses with a pill (Review is never a `[`/`]` destination either, by construction
    /// of `movableOrder`, but it is also never a valid STARTING column to move out of).
    static func moveSelected(forward: Bool, model: AppModel) {
        let today = Day.today()
        guard let id = model.selectedTaskID, let task = model.store.task(id) else { return }
        guard let current = BoardColumn.of(task, today: today) else { return }
        guard current != .review else {
            UndoToastCenter.shared.showNotice(String(localized: "board.pill.reviewlocked"))
            return
        }
        guard let idx = BoardColumn.movableOrder.firstIndex(of: current) else { return }
        let next = idx + (forward ? 1 : -1)
        guard BoardColumn.movableOrder.indices.contains(next) else { return }
        BoardDrop.move(id, to: BoardColumn.movableOrder[next], model: model, today: today)
    }
}
