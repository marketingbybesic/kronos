// What only the whole app can supply to the MCP server: the list on screen (for `next`), webhook
// delivery, and the two per-agent feeds (the away digest, agent-completion notifications) that
// only make sense while the real app and its store are alive.
// `MCPLiveController` finds this class by its Objective-C name when the server starts, so the
// controller itself (compiled alone by the self-tests) knows nothing of the app.

import AppKit
import KronosCore

@MainActor
@objc(KronosMCPAppBinding)
final class MCPAppBinding: NSObject {
    private static var delivery: WebhookDeliveryController?
    private static var runSupervisor: RunSupervisor?

    /// Called by `MCPLiveController` when the server starts.
    @objc(attachController:) static func attach(_ controller: AnyObject) {
        guard let live = controller as? MCPLiveController else { return }
        live.nextProvider = { Self.shownList() }
        if let hub = live.hub, let store = AppDelegate.shared?.store {
            delivery?.stop()
            let d = WebhookDeliveryController(hub: hub, store: store)
            hub.prune()
            d.start()
            delivery = d
            if let runs = live.runs {
                runSupervisor?.stop()
                let s = try? RunSupervisor(store: store, runs: runs)
                s?.start()
                runSupervisor = s
                AppDelegate.shared?.runSupervisor = s
                // Merge integration: point slice C's hand-off seam at the live supervisor, so
                // ⇧H / "Run again" actually launch. Reset to the inert default on detach below.
                if let s, let hub = live.hub, let model = AppDelegate.shared?.model,
                   let harness = try? HarnessStore(directory: KronosStore.containerDirectory()) {
                    model.runLauncher = SupervisorRunLauncher(supervisor: s, hub: hub, harness: harness, store: store)
                }
            }
        }
        if let hub = live.hub {
            AwayDigest.shared.start(hub: hub)
            if let store = AppDelegate.shared?.store {
                AgentDoneNotifications.shared.start(hub: hub, store: store)
            }
        }
    }

    @objc(detachController:) static func detach(_ controller: AnyObject) {
        delivery?.stop()
        delivery = nil
        // A supervised harness reports back over MCP; with the server stopping there is nowhere
        // for run_update/run_finish to land, so every live child is stopped along with it (B2:
        // this is also what runs on app quit, via applicationWillTerminate -> mcpLive.stop()).
        runSupervisor?.terminateAllForQuit()
        runSupervisor?.stop()
        runSupervisor = nil
        AppDelegate.shared?.runSupervisor = nil
        AppDelegate.shared?.model.runLauncher = NoHarnessRunLauncher()
        AwayDigest.shared.stop()
        AgentDoneNotifications.shared.stop()
        (controller as? MCPLiveController)?.nextProvider = nil
    }

    /// The list the window shows, its pin, and the task the menu bar shows. An empty head
    /// (no window, as under `--mcp-background`) makes the dispatcher fall back to Today.
    static func shownList() -> MCPNextCandidates? {
        guard let model = AppDelegate.shared?.model else { return nil }
        let head = model.shownListHead
        // Same chain as the menu bar: the current time block, then the pin, then the automatic focus.
        let bar = TimeBlocksModel(model: model).blockFocusTaskID ?? model.pinnedFocusTaskID ?? model.ordoFocus.taskID
        return MCPNextCandidates(listName: head.listName, ids: head.ids, pinned: model.pinnedFocusTaskID, barTaskID: bar)
    }
}
