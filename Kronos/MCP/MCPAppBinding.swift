// What only the whole app can supply to the MCP server: the list on screen (for `next`) and
// webhook delivery. `MCPLiveController` finds this class by its Objective-C name when the server
// starts, so the controller itself (compiled alone by the self-tests) knows nothing of the app.

import AppKit
import KronosCore

@MainActor
@objc(KronosMCPAppBinding)
final class MCPAppBinding: NSObject {
    private static var delivery: WebhookDeliveryController?

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
        }
    }

    @objc(detachController:) static func detach(_ controller: AnyObject) {
        delivery?.stop()
        delivery = nil
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
