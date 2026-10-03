// Kronos/App/DockMenu.swift
// macOS integration that needs no developer program: the Dock menu, URL / file entry points on the
// app delegate, and the one "bring the window forward" helper they share.
import AppKit
import KronosCore

extension AppDelegate {
    // MARK: Dock menu

    /// Quick add, Impuls, Capture, then the next three tasks. Rebuilt on every right-click, so it is
    /// always current; titles are cut at 40 characters to keep the menu one column wide.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard launchFailure == nil else { return nil }
        let menu = NSMenu()
        menu.addItem(dockItem(String(localized: "app.dock.quickadd"), #selector(dockQuickAdd)))
        menu.addItem(dockItem(String(localized: "app.dock.impuls"), #selector(dockImpuls)))
        menu.addItem(dockItem(String(localized: "app.dock.capture"), #selector(dockCapture)))
        let next = nextTasksForDock(limit: 3)
        if !next.isEmpty {
            menu.addItem(.separator())
            for task in next {
                let title = task.title.isEmpty ? String(localized: "app.dock.untitled") : task.title
                let item = NSMenuItem(title: Self.dockTitle(title), action: #selector(dockOpenTask(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = task.id
                menu.addItem(item)
            }
        }
        return menu
    }

    /// The Now card's task first (pin, else automatic Ordo), then the rest of the list in the order the
    /// list itself shows them, open tasks only.
    private func nextTasksForDock(limit: Int) -> [KTask] {
        var result: [KTask] = []
        if let id = model.focusTaskID, let t = store.task(id), KStatus.open.contains(t.status) { result.append(t) }
        for t in ListContext(model: model).rows where KStatus.open.contains(t.status) {
            if result.count >= limit { break }
            if !result.contains(where: { $0.id == t.id }) { result.append(t) }
        }
        return Array(result.prefix(limit))
    }

    static func dockTitle(_ title: String) -> String {
        let one = title.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return one.count > 40 ? String(one.prefix(39)) + "…" : one
    }

    private func dockItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func dockQuickAdd() { NotificationCenter.default.post(name: .kronosQuickAddPanelRequested, object: nil) }
    @objc private func dockImpuls() { model.isImpulsOpen = true; bringForward() }
    @objc private func dockCapture() { model.openCapture(); bringForward() }
    @objc private func dockOpenTask(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, model.openTaskByID(id) else { return }
        bringForward()
    }

    // MARK: Window

    /// Window forward, also from a hidden `--mcp-background` launch.
    func bringForward() {
        _ = mcpBackground.restore()
        NSApp.activate(ignoringOtherApps: true)
        if let win = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) {
            if win.isMiniaturized { win.deminiaturize(nil) }
            win.makeKeyAndOrderFront(nil)
        }
    }

    /// A login launch is menu bar only: the main window is ordered out (not closed), so a Dock click
    /// or the menu bar item brings it back through `bringForward()`.
    func hideWindowsForLoginLaunch() {
        for win in NSApp.windows where win.canBecomeMain && !(win is NSPanel) { win.orderOut(nil) }
    }

    // MARK: URL scheme and documents

    /// Registered before launch finishes so a cold `open kronos://…` is not lost.
    func registerURLHandler() {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleGetURL(_:withReply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: s) else { return }
        URLSchemeRouter.handle(url, model: model)
    }

    /// AppKit's own route for kronos:// URLs and for opened `.kronos.json` files.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.isFileURL { BackupOpen.present(url, model: model) } else { URLSchemeRouter.handle(url, model: model) }
        }
    }
}


// MARK: - Menu bar flash

/// Capturing from another app (Services) gives no other sign that it worked: the menu bar item
/// lights for a moment, as a pressed status item does. A highlight, not an animation, so Reduce
/// Motion needs no special case.
@MainActor
enum MenuBarFlash {
    /// Only when Kronos is in the background; with the app in front its own toast says it.
    static func shouldFlash(appIsActive: Bool, hermetic: Bool) -> Bool { !appIsActive && !hermetic }

    static func flashIfBackground() {
        guard shouldFlash(appIsActive: NSApp.isActive, hermetic: KronosEnv.isHermetic),
              let button = statusButton() else { return }
        button.highlight(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { button.highlight(false) }
    }

    /// The status bar button of this app, found through its status bar window.
    private static func statusButton() -> NSStatusBarButton? {
        func find(_ view: NSView?) -> NSStatusBarButton? {
            guard let view else { return nil }
            if let button = view as? NSStatusBarButton { return button }
            for sub in view.subviews { if let hit = find(sub) { return hit } }
            return nil
        }
        for win in NSApp.windows where String(describing: type(of: win)).contains("StatusBar") {
            if let button = find(win.contentView) { return button }
        }
        return nil
    }
}
