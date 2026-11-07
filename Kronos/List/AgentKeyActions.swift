// Kronos/List/AgentKeyActions.swift
// Kronos v1.2 Phase 2 slice C3: the hand-off / stop actions ⌃⌘H, ⌃⇧⌘H and ⌘. perform, factored
// out so BOTH the normal `.onKeyPress` path (TaskListScreen+AgentKeys.swift) and
// AgentKeyMonitor.swift's local-event-monitor fallback call the exact same write — one path,
// never two to drift.
import KronosCore

@MainActor
enum AgentKeyActions {
    /// H / ⇧H: opens the agent-picker overlay (ListHandoffPick.swift) on the whole selection —
    /// one task, or the multi-selection's full set.
    static func handoff(_ model: AppModel, andRun: Bool) {
        let ids = model.selectedIDs.count > 1 ? Array(model.selectedIDs) : (model.selectedTaskID.map { [$0] } ?? [])
        guard !ids.isEmpty else { return }
        model.handoffRequest = HandoffRequest(taskIDs: ids, andRun: andRun)
    }

    /// ⌘.: stops the active run of the selected task. person action, no confirmation (plan B4) —
    /// silently does nothing without a selected task or an active run, same as every other key
    /// here when there is nothing to act on. `LiveRuns`, not `model.runs`: the latter is nil
    /// whenever MCP is off (the default, scratch-store state in every live UI test and for any
    /// person who never opened Settings > AI access) — `LiveRuns` opens its own device-local
    /// handle on the same run-contract store, same as every other read-mostly run UI (menu bar
    /// counts, Today's quiet line, Review next) already does.
    static func stopSelectedRun(_ model: AppModel) {
        guard let id = model.selectedTaskID, let run = LiveRuns.activeRun(taskID: id) else { return }
        LiveRuns.stop(runID: run.id)
        model.didMutate()
        UndoToastCenter.shared.showNotice(String(format: String(localized: "run.stopped.notice"), RunAgentNaming.displayName(forSlug: run.agentSlug)))
    }
}
