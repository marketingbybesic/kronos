// Live steps for the second round of follow-ups: Earlier opening by itself when Today has nothing of
// its own, Settings' "Use Control shortcuts" button, a Settings request that names a tab, the sort
// card's break-down request reaching the Steps section, and a collapsed inspector opening for a
// title or notes request. Run alone with `--only group:E-POLISH2`.
#if !RELEASE
import AppKit
import SwiftUI
import KronosCore

/// A borderless window that can take key focus, so presses reach the hosted controls.
private final class EPolish2KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

@MainActor
extension LiveUITest {

    private static let ep2LastTabKey = "kronos.settings.lastTab"

    static func ePolish2Steps(_ model: AppModel) async {
        let breakMode = ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil
        await setWindowSize(width: 1500, height: 900)
        await runStep(model, scope: .today) { await ep2EarlierOpensWhenTodayIsEmpty($0, breakMode: breakMode) }
        await runStep(model, scope: .all) { await ep2ControlSchemeButton($0, breakMode: breakMode) }
        await runStep(model, scope: .all) { await ep2SettingsTabRequest($0, breakMode: breakMode) }
        await runStep(model, scope: .all) { await ep2BreakdownBridge($0, breakMode: breakMode) }
        await runStep(model, scope: .all) { await ep2InspectorOpensForRequests($0, breakMode: breakMode) }
        await resetState(model)
    }

    // MARK: Earlier

    /// Three tasks four days late and nothing else: Today lists them without a press (a collapsed
    /// "Earlier" under a bare 0 hid them); the person's own close still holds.
    private static func ep2EarlierOpensWhenTodayIsEmpty(_ model: AppModel, breakMode: Bool) async {
        let store = model.store
        let today = Day.today()
        ListEarlierState.shared.resetChoice()
        // Park everything the list holds so Today has nothing of its own.
        let parked = (ListContext(model: model).rows + ListContext(model: model).earlier).map(\.id)
        let parkedAt = Date()
        for id in parked { store.updateNoUndo(id) { $0.deletedAt = parkedAt } }
        let late = (1...3).map { i -> KTask in
            let t = store.createNoUndo(title: "Waiting probe \(i)", notes: "", project: nil, status: .todo, priority: .none, dueDay: today - 4)
            store.updateNoUndo(t.id) { $0.carryCount = 4; $0.originalDueDay = today - 4 }
            return t
        }
        let ids = Set(late.map(\.id))
        defer {
            for t in late { store.softDeleteNoUndo(t.id) }
            for id in parked { store.updateNoUndo(id) { $0.deletedAt = nil } }
            ListEarlierState.shared.resetChoice()
            model.didMutate()
        }
        model.didMutate()
        await settle(300)
        let opened = await waitUntil(timeout: 3) { Set(ListContext(model: model).rows.map(\.id)) == ids }
        let ctx = ListContext(model: model)
        record("with nothing of its own in Today, the three carried tasks are listed without opening Earlier",
               (breakMode ? !opened : opened) && ctx.currentCount == 0 && ctx.earlier.count == 3,
               "rows=\(ctx.rows.count) current=\(ctx.currentCount) earlier=\(ctx.earlier.count)")

        // The person's own close is respected.
        _ = await click("today.earlier.header")
        let closed = await waitUntil(timeout: 2) { ListContext(model: model).rows.isEmpty }
        record("pressing the Earlier header closes it again and the choice holds",
               closed && ListEarlierState.shared.userChoice == false,
               "rows=\(ListContext(model: model).rows.count) choice=\(String(describing: ListEarlierState.shared.userChoice))")

        // With a task of its own, an untouched Earlier stays collapsed.
        ListEarlierState.shared.resetChoice()
        let own = store.createNoUndo(title: "Own probe", notes: "", project: nil, status: .todo, priority: .none, dueDay: today)
        defer { store.softDeleteNoUndo(own.id); model.didMutate() }
        model.didMutate()
        await settle(300)
        let rowIDs = Set(ListContext(model: model).rows.map(\.id))
        record("with a task of its own in Today, Earlier stays collapsed until opened",
               rowIDs.contains(own.id) && rowIDs.isDisjoint(with: ids),
               "rows=\(rowIDs.count) ownShown=\(rowIDs.contains(own.id))")
    }

    // MARK: Settings

    private static func ep2SettingsWindow(_ model: AppModel, tab: SettingsTab) -> NSWindow {
        let host = NSHostingController(rootView: SettingsScreen(model: model, initialTab: tab).frame(width: 900, height: 1100).background(Tok.bg))
        let w = EPolish2KeyableWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 1100),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentViewController = host
        w.setContentSize(NSSize(width: 900, height: 1100))
        w.center()
        return w
    }

    /// "Use Control shortcuts" moves window shortcuts from Command to Control through the registry,
    /// keeps Undo and Redo on Command, says how many moved, and Reset to defaults undoes it.
    private static func ep2ControlSchemeButton(_ model: AppModel, breakMode: Bool) async {
        let mainWindow: NSWindow = window
        HotkeyRegistry.resetToDefaults()
        defer {
            HotkeyRegistry.resetToDefaults()
            window = mainWindow
            mainWindow.makeKeyAndOrderFront(nil)
        }
        let win = ep2SettingsWindow(model, tab: .shortcuts)
        window = win
        defer { win.orderOut(nil) }
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        _ = await waitUntil(timeout: 5) { UITestAnchors.frames["settings.shortcuts.controlscheme"] != nil }
        await settle(300)
        // Hand-written: the chords below are Command chords by default, and Undo/Redo never move.
        let commandIDs = ["window.palette", "window.impuls", "window.capture"]
        let keepIDs = ["window.undo", "window.redo"]
        let before = commandIDs.map { HotkeyRegistry.current(for: $0)?.command == true && HotkeyRegistry.current(for: $0)?.control != true }
        let clicked = await click("settings.shortcuts.controlscheme")
        let resultShown = await waitUntil(timeout: 3) { UITestAnchors.frames["settings.shortcuts.controlscheme.result"] != nil }
        let after = commandIDs.compactMap { HotkeyRegistry.current(for: $0) }
        let movedCount = after.filter { $0.control && !$0.command }.count
        let kept = keepIDs.allSatisfy { HotkeyRegistry.current(for: $0)?.command == true }
        record("the Control button moves the Command window shortcuts to Control and leaves Undo and Redo on Command",
               clicked && before.allSatisfy { $0 } && (breakMode ? movedCount == 0 : movedCount >= 1) && kept,
               "clicked=\(clicked) before=\(before) moved=\(movedCount)/\(commandIDs.count) undoRedoKept=\(kept)")
        record("the button says how many shortcuts moved", resultShown, "result=\(resultShown)")

        // Reset to defaults (the real button, with its confirmation) undoes the preset.
        ep2ScrollToBottom(win.contentView)
        await settle(400)
        _ = await waitUntil(timeout: 3) { UITestAnchors.frames["settings.shortcuts.reset"].map { $0.minY > 0 && $0.maxY < 1100 } ?? false }
        _ = await click("settings.shortcuts.reset")
        _ = await waitUntil(timeout: 3) { UITestAnchors.frames["settings.shortcuts.reset.confirm"] != nil }
        await settle(300)
        let resetDone = await click("settings.shortcuts.reset.confirm")
        await settle(300)
        let restored = commandIDs.allSatisfy { HotkeyRegistry.current(for: $0)?.command == true && HotkeyRegistry.current(for: $0)?.control != true }
        record("Reset to defaults puts every Command shortcut back", resetDone && restored,
               "pressed=\(resetDone) restored=\(restored)")
    }

    /// Scrolls the biggest scroll view under `view` to its end (the Reset row sits below the long table).
    private static func ep2ScrollToBottom(_ view: NSView?) {
        func scrollViews(_ v: NSView) -> [NSScrollView] {
            ((v as? NSScrollView).map { [$0] } ?? []) + v.subviews.flatMap(scrollViews)
        }
        guard let view else { return }
        let tallest = scrollViews(view).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
        guard let sv = tallest, let doc = sv.documentView else { return }
        let y = max(0, doc.frame.height - sv.contentView.bounds.height)
        sv.contentView.scroll(to: NSPoint(x: 0, y: y))
        sv.reflectScrolledClipView(sv.contentView)
    }

    /// A request naming a tab moves an open Settings window there. The app's own handler opens the
    /// real Settings window as well; it starts on the stored tab (General) and is closed after.
    private static func ep2SettingsTabRequest(_ model: AppModel, breakMode: Bool) async {
        let mainWindow: NSWindow = window
        let priorTab = KronosEnv.defaults.object(forKey: ep2LastTabKey)
        KronosEnv.defaults.set("general", forKey: ep2LastTabKey)
        let windowsBefore = Set(NSApp.windows.map { ObjectIdentifier($0) })
        defer {
            for w in NSApp.windows where !windowsBefore.contains(ObjectIdentifier(w)) { w.orderOut(nil) }
            if let priorTab { KronosEnv.defaults.set(priorTab, forKey: ep2LastTabKey) } else { KronosEnv.defaults.removeObject(forKey: ep2LastTabKey) }
            window = mainWindow
            mainWindow.makeKeyAndOrderFront(nil)
        }
        let win = ep2SettingsWindow(model, tab: .general)
        window = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        _ = await waitUntil(timeout: 5) { UITestAnchors.frames["settings.rail.general"] != nil }
        await settle(300)
        let startedOnGeneral = UITestAnchors.frames["settings.shortcuts.search"] == nil

        NotificationCenter.default.post(name: .kronosSettingsRequested, object: nil, userInfo: ["tab": breakMode ? "nonsense" : "shortcuts"])
        let moved = await waitUntil(timeout: 3) { UITestAnchors.frames["settings.shortcuts.search"] != nil }
        record("a Settings request that names a tab moves the open window to it",
               startedOnGeneral && moved, "startedOnGeneral=\(startedOnGeneral) shortcutsShown=\(moved)")
        win.orderOut(nil)
    }

    // MARK: Inspector

    /// The sort card's B posts a bare request; the Steps section opens its break-down preview.
    private static func ep2BreakdownBridge(_ model: AppModel, breakMode: Bool) async {
        let store = model.store
        let t = store.create(title: "Breakdown bridge probe")
        defer { store.softDeleteNoUndo(t.id); model.didMutate() }
        model.didMutate()
        model.selectedTaskID = t.id
        _ = await waitUntil(timeout: 3) { UITestAnchors.frames["inspector.steps"] != nil }
        await settle(300)
        let before = UITestAnchors.frames["inspector.breakdown.preview"] == nil
        if !breakMode {
            NotificationCenter.default.post(name: Notification.Name("kronosBreakdownRequested"), object: nil, userInfo: ["taskID": t.id])
        }
        let opened = await waitUntil(timeout: 3) { UITestAnchors.frames["inspector.breakdown.preview"] != nil }
        record("the sort card's break-down request opens the Steps section's preview",
               before && opened, "closedBefore=\(before) opened=\(opened)")
    }

    /// An inspector the person collapsed opens for a request to type in the title or the notes.
    private static func ep2InspectorOpensForRequests(_ model: AppModel, breakMode: Bool) async {
        let store = model.store
        let t = store.create(title: "Collapsed inspector probe", notes: "Notes for the probe")
        defer { store.softDeleteNoUndo(t.id); model.didMutate() }
        model.didMutate()
        model.selectedTaskID = t.id
        _ = await waitUntil(timeout: 3) { UITestAnchors.frames["inspector.title"] != nil }
        await settle(300)

        func collapse() async {
            if UITestAnchors.frames["inspector.title"] != nil {
                NotificationCenter.default.post(name: .kronosToggleInspectorRequested, object: nil)
                _ = await waitUntil(timeout: 3) { UITestAnchors.frames["inspector.title"] == nil }
                await settle(300)
            }
        }
        await collapse()
        let hidden = UITestAnchors.frames["inspector.title"] == nil
        if !breakMode {
            NotificationCenter.default.post(name: UIRequests.focusInspectorTitle, object: nil, userInfo: ["taskID": t.id])
        }
        let titleFocused = await waitUntil(timeout: 4) { (window.firstResponder as? NSTextView)?.string == "Collapsed inspector probe" }
        record("a title request opens a collapsed inspector and puts the cursor in the title",
               hidden && titleFocused, "hiddenBefore=\(hidden) focused=\(titleFocused)")

        window.makeFirstResponder(nil)
        await collapse()
        if !breakMode {
            NotificationCenter.default.post(name: .kronosFocusNotesRequested, object: nil, userInfo: ["taskID": t.id])
        }
        let notesFocused = await waitUntil(timeout: 4) { (window.firstResponder as? NSTextView)?.string == "Notes for the probe" }
        record("a notes request opens a collapsed inspector and puts the cursor in the notes",
               notesFocused, "focused=\(notesFocused)")
        window.makeFirstResponder(nil)
    }
}
#endif
