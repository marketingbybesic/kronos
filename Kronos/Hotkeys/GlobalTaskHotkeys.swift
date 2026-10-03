// Kronos/Hotkeys/GlobalTaskHotkeys.swift
// Two system-wide keys that act on tasks without opening Kronos first:
//   ⌃⌥⏎ Complete current: completes the focus task (the pin, else the first eligible row of the
//        list shown), with the completion sound and the undo pill, from any app.
//   ⌃⌥P Pick one: brings Kronos forward with the Pick one card open.
// Bindings come from HotkeyRegistry (`global.completecurrent`, `global.pickone`). Settings records
// them through the registry's own recorder (they have no KeyboardShortcuts recorder of their
// own), so this file mirrors the registry's current binding into the KeyboardShortcuts name at
// start and on every `HotkeyRegistry.changed`. Never registered in a hermetic run (live test,
// snapshots, custom store dir): no global hotkey may be taken by a test.
import AppKit
import KeyboardShortcuts
import KronosCore

extension KeyboardShortcuts.Name {
    static let completeCurrent = Self("completeCurrent",
                                      default: HotkeyRegistry.entries.first { $0.id == "global.completecurrent" }!.defaultBinding.globalShortcut!)
    static let pickOne = Self("pickOne",
                              default: HotkeyRegistry.entries.first { $0.id == "global.pickone" }!.defaultBinding.globalShortcut!)
}

@MainActor
enum GlobalTaskHotkeys {
    private static var started = false
    private static var token: NSObjectProtocol?
    private weak static var model: AppModel?

    /// Registers both keys once (later calls only refresh the model). The list calls it on
    /// appear, so the keys exist as soon as the main window does.
    static func start(model: AppModel) {
        self.model = model
        guard !started, !KronosEnv.isHermetic else { return }
        started = true
        syncFromRegistry()
        KeyboardShortcuts.onKeyUp(for: .completeCurrent) {
            MainActor.assumeIsolated {
                guard let model = Self.model else { return }
                _ = completeCurrent(model: model)
            }
        }
        KeyboardShortcuts.onKeyUp(for: .pickOne) {
            MainActor.assumeIsolated {
                guard let model = Self.model else { return }
                openPickOne(model: model)
            }
        }
        token = NotificationCenter.default.addObserver(forName: HotkeyRegistry.changed, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { syncFromRegistry() }
        }
    }

    /// The registry's binding (override or default) becomes the live global shortcut.
    private static func syncFromRegistry() {
        for (id, name) in [("global.completecurrent", KeyboardShortcuts.Name.completeCurrent), ("global.pickone", .pickOne)] {
            let shortcut = HotkeyRegistry.current(for: id)?.globalShortcut
            if KeyboardShortcuts.getShortcut(for: name) != shortcut { KeyboardShortcuts.setShortcut(shortcut, for: name) }
        }
    }

    /// The task "Complete current" acts on: the pin, else the first eligible row of the list shown.
    static func currentTask(model: AppModel) -> KTask? {
        let id = model.pinnedFocusTaskID ?? model.nextFromShownList?.id ?? model.ordoFocus.taskID
        guard let id, let task = model.store.task(id), KStatus.open.contains(task.status) else { return nil }
        return task
    }

    /// Completes the current task through the list's own completion path (pill, hand-off to the
    /// next task, the completion sound Core announces). False when there is nothing to complete.
    @discardableResult
    static func completeCurrent(model: AppModel) -> Bool {
        guard let task = currentTask(model: model) else { return false }
        ListCompletion.toggle(task, store: model.store, model: model)
        return true
    }

    /// Kronos forward, main window shown, the Pick one card open.
    static func openPickOne(model: AppModel) {
        NSApp.activate(ignoringOtherApps: true)
        if let main = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) {
            main.makeKeyAndOrderFront(nil)
        }
        model.isImpulsOpen = true
    }
}
