// Kronos/Flow/FlowScreen+Keys.swift
// Flow's own keyboard (E5): arrows walk the dependency graph, Return opens the inspector, ⌫
// removes the dependency edge ←/→ just crossed, ⌘. stops the selected card's active run. W/H/⇧H
// and L live inline in FlowScreen.swift's `body` (one line each, no extra state to thread here).
import SwiftUI
import KronosCore

extension FlowScreen {
    /// ↑/↓ move within the focused card's column; →/← jump to its first dependent/prerequisite.
    /// Crossing an edge this way is what puts it "in focus" for `removeFocusedEdge()` below.
    func move(_ press: KeyPress, _ ctx: FlowContext) -> KeyPress.Result {
        guard !ctx.visibleIDs.isEmpty else { return .ignored }
        guard let current = model.selectedTaskID, ctx.visibleIDs.contains(current) else {
            if let first = ctx.result.columns.first?.taskIDs.first { select(first) }
            return .handled
        }
        switch press.key {
        case .upArrow, .downArrow:
            focusedEdge = nil
            if let next = FlowNav.neighbor(of: current, delta: press.key == .upArrow ? -1 : 1, result: ctx.result) {
                select(next)
            }
        case .rightArrow:
            if let next = FlowNav.firstDependent(of: current, result: ctx.result) {
                focusedEdge = FlowLayout.Edge(from: current, to: next)
                select(next)
            }
        case .leftArrow:
            if let next = FlowNav.firstPrerequisite(of: current, result: ctx.result) {
                focusedEdge = FlowLayout.Edge(from: next, to: current)
                select(next)
            }
        default:
            return .ignored
        }
        return .handled
    }

    /// Return: open the focused card in the inspector and put the keyboard in its title, exactly
    /// like the list's own Return (`TaskListScreen+Keys.swift`'s `selectAndOpen`).
    func openSelected(_ ctx: FlowContext) {
        guard let id = model.selectedTaskID, ctx.visibleIDs.contains(id) else { return }
        _ = model.openDetails(taskID: id)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: UIRequests.focusInspectorTitle, object: nil, userInfo: ["taskID": id])
        }
    }

    /// ⌫ with an edge focused: the dependent no longer waits on the prerequisite it was reached
    /// from. One write, one undo pill — the same shape every other list write in this app uses.
    func removeFocusedEdge() {
        guard let edge = focusedEdge, let task = model.store.task(edge.to) else { return }
        let base = task.waitsOn
        let updated = base.filter { $0 != edge.from }
        guard updated != base else { return }
        model.store.setWaitsOn(edge.to, updated, editBase: base)
        if let prerequisite = model.store.task(edge.from) {
            model.commit(String(format: String(localized: "flow.undo.waitsonremoved"), task.title, prerequisite.title))
        } else {
            // The prerequisite vanished between the edge being selected and ⌫ being pressed (an
            // external delete) — still a real write, so it still gets a pill, just the
            // single-title fallback message since the prerequisite's title is gone too.
            model.commit(String(format: String(localized: "flow.undo.waitsonremoved.gone"), task.title))
        }
        focusedEdge = nil
    }

    /// ⌘.: stops the focused card's active run, if it has one. A no-op otherwise (no error, no
    /// pill — the key simply does nothing on a card with nothing running). Goes through
    /// `LiveRuns.stop` (Kronos/MCP/LiveRuns.swift), not `RunStore.stop` directly: a
    /// Kronos-launched run needs its real process sent SIGTERM via the live `RunSupervisor`,
    /// not just its row flipped to "stopped" while the process keeps running unsupervised.
    func stopRun(for taskID: UUID, _ ctx: FlowContext) {
        guard let runStore = ctx.runStore, let run = runStore.activeRun(taskID: taskID) else { return }
        LiveRuns.stop(runID: run.id)
        model.didMutate()
        // Same notice List's own ⌘. shows (TaskListScreen+AgentKeys.swift's `stopSelectedRun`) —
        // stopping is not undoable, so a notice, not a commit() pill.
        UndoToastCenter.shared.showNotice(String(format: String(localized: "run.stopped.notice"), RunAgentNaming.displayName(forSlug: run.agentSlug)))
    }
}

/// Pure arrow-key graph walk over one `FlowLayout.Result` — no store access, easy to read and
/// easy to reason about independent of SwiftUI.
enum FlowNav {
    static func firstDependent(of id: UUID, result: FlowLayout.Result) -> UUID? {
        firstInReadingOrder(Set(result.edges.filter { $0.from == id }.map(\.to)), result: result)
    }

    static func firstPrerequisite(of id: UUID, result: FlowLayout.Result) -> UUID? {
        firstInReadingOrder(Set(result.edges.filter { $0.to == id }.map(\.from)), result: result)
    }

    static func neighbor(of id: UUID, delta: Int, result: FlowLayout.Result) -> UUID? {
        guard let column = result.columns.first(where: { $0.taskIDs.contains(id) }),
              let idx = column.taskIDs.firstIndex(of: id) else { return nil }
        let target = idx + delta
        guard column.taskIDs.indices.contains(target) else { return nil }
        return column.taskIDs[target]
    }

    /// The first of `ids` in reading order: columns left to right, then top to bottom within
    /// each — so → always lands on the topmost dependent as drawn, never an arbitrary one.
    private static func firstInReadingOrder(_ ids: Set<UUID>, result: FlowLayout.Result) -> UUID? {
        guard !ids.isEmpty else { return nil }
        for column in result.columns {
            if let hit = column.taskIDs.first(where: { ids.contains($0) }) { return hit }
        }
        return nil
    }
}
