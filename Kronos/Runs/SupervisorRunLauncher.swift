// Kronos v1.2 merge integration (orchestrator): slice C's `RunLaunching` seam
// (Kronos/List/RunLaunching.swift) pointed at slice B's real `RunSupervisor`. ⇧H "Hand off and
// run", the matching context-menu item and the inspector's "Run again" all reach the harness
// through this object; while the MCP server is down, `AppModel.runLauncher` falls back to
// `NoHarnessRunLauncher` again (MCPAppBinding.detach), so the refusal pill always names a reason.
import Foundation
import KronosCore

@MainActor
final class SupervisorRunLauncher: RunLaunching {
    private weak var supervisor: RunSupervisor?
    private let hub: AgentHub
    private let harness: HarnessStore
    private let store: any TaskStoring

    init(supervisor: RunSupervisor, hub: AgentHub, harness: HarnessStore, store: any TaskStoring) {
        self.supervisor = supervisor
        self.hub = hub
        self.harness = harness
        self.store = store
    }

    func canLaunch(agentID: UUID) -> RunLaunchAvailability {
        guard hub.agent(id: agentID) != nil else {
            return .unavailable(reason: String(localized: "run.launch.noharness"))
        }
        switch harness.validate(agentID: agentID) {
        case .ok: return .available
        case .unpinned: return .unavailable(reason: String(localized: "agents.harness.unpinned"))
        case .changed: return .unavailable(reason: String(localized: "agents.harness.changed"))
        }
    }

    /// A refusal the pre-flight `canLaunch` cannot see (the concurrency cap, a claim raced in by
    /// another agent, a harness swapped between check and launch) is shown as the standard pill
    /// right here — slice C's call sites deliberately treat `launch` as fire-and-report
    /// (ListHandoffPick.attempt), so swallowing the error silently would violate B2's cap pill.
    func launch(taskID: UUID, agentID: UUID, model: String?) throws {
        guard let supervisor, let row = hub.agent(id: agentID),
              let identity = hub.identity(slug: row.slug),
              let task = store.task(taskID) else { return }
        do {
            try supervisor.launch(task: task, agent: identity, model: model)
        } catch {
            UndoToastCenter.shared.showNotice(RunSupervisor.message(for: error))
        }
    }
}
