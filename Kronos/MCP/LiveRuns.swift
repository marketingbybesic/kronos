// Kronos/MCP/LiveRuns.swift
// A read-mostly `RunStore` handle for UI badges that do not already hold one: the menu bar's
// review/running count (MenuBarOrdoController.swift, MenuBarPopoverContent.swift), the Today
// header's quiet line (TaskListScreen+ReviewRunning.swift) and Review next's run section
// (ReviewNextRunSection.swift) — Kronos v1.2 Phase 2 slice D. Opened once and reused: SwiftData
// reads straight off disk, so a cached context never serves a stale row, the same reasoning
// `AgentHub(directory:)` callers elsewhere in this app rely on for a fresh handle rather than a
// shared live model. Never the identity side of a run (start/update/finish, which need an
// `AgentIdentity` and belong to the MCP layer's own `RunStore` in `MCPLiveController`): only
// reads, plus `stop`, which `RunStore.stop` is deliberately person-only (no identity) for.
// `stop` itself goes through the live `RunSupervisor` when one exists so a Kronos-launched
// process is actually sent SIGTERM (then SIGKILL on the next tick) rather than only having
// its run row flipped to "stopped" while the real process keeps running unsupervised —
// `RunSupervisorEngine.stop` already falls back to a DB-only stop for a run it never
// spawned, so routing through it here is correct for every run, not only Kronos-launched ones.
import Foundation
import KronosCore

@MainActor
enum LiveRuns {
    private static var cached: RunStore?

    private static func store() -> RunStore? {
        if let cached { return cached }
        guard let appStore = AppDelegate.shared?.store,
              let made = try? RunStore(directory: KronosStore.containerDirectory(), store: appStore, hub: nil) else {
            return nil
        }
        cached = made
        return made
    }

    static func activeRun(taskID: UUID) -> KAgentRun? { store()?.activeRun(taskID: taskID) }
    static func activeRuns() -> [KAgentRun] { store()?.activeRuns() ?? [] }
    static func runs(taskID: UUID) -> [KAgentRun] { store()?.runs(taskID: taskID) ?? [] }
    static func stop(runID: UUID) {
        if let supervisor = AppDelegate.shared?.runSupervisor { supervisor.stopRun(runID: runID); return }
        store()?.stop(runID: runID)
    }
}
