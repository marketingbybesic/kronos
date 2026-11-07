// Kronos/Board/BoardScreen.swift
// Plan v1.2 Phase 2, F2: a kanban view of whatever `model.scope` currently shows — To do ·
// In progress · Waiting · Review · Done today. Reuses `ScopeFilter.matches`, the SAME single
// source of scope membership the List view and the sidebar counts use (its own header comment:
// "the sidebar's count and the list's rows must come from the same rule, or the badge says 7
// while the list shows 6"), with closed tasks included so "Done today" has something to show —
// Board decides for itself which closed task belongs in that one column, same as the Today
// list already decides which closed tasks are "today's".
//
// Mounting: AppShellView's center-pane switch has `case .board: BoardScreen(model: model)`
// (added by the orchestrator at the Phase 2 batch merge), the same place `FlowScreen` mounts.
import SwiftUI
import KronosCore

/// The five columns a Board ever shows. `Review` is read-only: nothing drops into it (there is
/// no status write that means "awaiting the person's check"), and a card already there refuses to
/// leave by drag or by `[`/`]` — only `A`/`X` in Review-next (slice D) change that state.
enum BoardColumn: String, CaseIterable, Identifiable {
    case todo, inProgress, waiting, review, doneToday
    var id: String { rawValue }

    /// The column order `[` / `]` move a selected card through — Review is never a destination,
    /// so it is excluded here even though it is still a real column with real cards.
    static let movableOrder: [BoardColumn] = [.todo, .inProgress, .waiting, .doneToday]

    var titleKey: String {
        switch self {
        case .todo: return "status.todo"
        case .inProgress: return "status.inprogress"
        case .waiting: return "status.waiting"
        case .review: return "review.sidebar.title"
        case .doneToday: return "board.column.donetoday"
        }
    }

    /// Which column `task` belongs in, or nil when it belongs in none of the five (someday,
    /// canceled, or done on an earlier day — Board shows only what these five columns mean).
    static func of(_ task: KTask, today: Int) -> BoardColumn? {
        if task.reviewRaw == ReviewState.awaitingCheck { return .review }
        switch task.status {
        case .todo: return .todo
        case .inProgress: return .inProgress
        case .waiting: return .waiting
        case .done:
            guard let completed = task.completedAt else { return nil }
            return Day.from(completed) == today ? .doneToday : nil
        case .someday, .canceled: return nil
        }
    }
}

struct BoardScreen: View {
    @Bindable var model: AppModel
    @State private var dropTarget: BoardColumn?
    @FocusState private var isFocused: Bool
    @State private var hotkeyRevision = 0   // bumped on HotkeyRegistry.changed so `[`/`]` pick up a live rebind

    /// A narrow, Board-only column width: not a cross-screen value, so it is a local constant
    /// rather than a new `Metrics` token (Tokens.swift is shared chrome used everywhere).
    private let columnWidth: CGFloat = 248

    private var today: Int { Day.today() }

    /// Registry ids for `[`/`]` (HotkeyRegistry.swift, scope `.board`) — read live so a Settings
    /// rebind actually changes what the key does, not just what the keymap card shows. Same
    /// "bumped revision + rebuilt character set" shape `TaskListScreen+Parts.swift`'s own
    /// `listCharacterSet` uses for its rebindable letters.
    private static let leftID = "board.movecolumn.left"
    private static let rightID = "board.movecolumn.right"

    private var boardCharacterSet: CharacterSet {
        _ = hotkeyRevision
        let left = HotkeyRegistry.current(for: Self.leftID)?.key ?? "["
        let right = HotkeyRegistry.current(for: Self.rightID)?.key ?? "]"
        return CharacterSet(charactersIn: left + right)
    }

    private var tasks: [KTask] {
        let today = self.today
        return model.store.allTasks().filter { ScopeFilter.matches($0, scope: model.scope, today: today, includeClosed: true) }
    }

    private func rows(_ column: BoardColumn) -> [KTask] {
        let today = self.today
        let matching = tasks.filter { BoardColumn.of($0, today: today) == column }
        return KTaskSorter.sorted(matching, by: KSortDescriptor.default)
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: Space.x3) {
                ForEach(BoardColumn.allCases) { column in
                    BoardColumnView(model: model, column: column, tasks: rows(column), dropTarget: $dropTarget)
                        .frame(width: columnWidth)
                }
            }
            .padding(Space.x4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tok.bg)
        .focusable(true, interactions: .activate)
        .focused($isFocused)
        .onAppear { isFocused = true }
        // Selecting a card (a `Button` tap) can move SwiftUI's own internal focus onto that
        // card, away from this container's `.focusable` region, so `[`/`]` go silently nowhere
        // right after a click — re-assert it the same way `.onAppear` already does once.
        .onChange(of: model.selectedTaskID) { _, _ in isFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: HotkeyRegistry.changed).receive(on: DispatchQueue.main)) { _ in hotkeyRevision += 1 }
        .onKeyPress(characters: boardCharacterSet) { press in
            guard let ch = press.characters.first else { return .ignored }
            let right = HotkeyRegistry.current(for: Self.rightID)?.key ?? "]"
            BoardKeyActions.moveSelected(forward: String(ch).lowercased() == right, model: model)
            return .handled
        }
        .uiTestAnchor("board.screen")
    }
}
