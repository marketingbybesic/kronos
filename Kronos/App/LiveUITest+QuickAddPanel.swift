// Kronos/App/LiveUITest+QuickAddPanel.swift
// The global quick add panel: a borderless NSPanel that must become key and take typing.
#if !RELEASE
import AppKit
import SwiftUI
import KronosCore

@MainActor
extension LiveUITest {
    /// 9. The global quick add panel is a borderless NSPanel: it must still become KEY and take
    /// typing (a plain borderless panel cannot), create subtasks, and close on Return.
    static func quickAddPanelTypes(_ model: AppModel) async {
        let store = model.store
        let main = window!
        AppDelegate.shared.quickAdd.toggle()
        await waitUntil(timeout: 4) { NSApp.windows.contains { $0 is NSPanel && $0.isVisible && $0 !== main && $0.canBecomeKey } }
        await waitUntil(timeout: 2) { NSApp.keyWindow is NSPanel }
        // The text field takes focus a beat after the panel shows: typing before that is lost.
        await waitUntil(timeout: 3) { (NSApp.keyWindow?.firstResponder is NSTextView) }
        await waitStable { NSApp.keyWindow?.frame ?? .zero }
        guard let panel = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible && $0 !== main && $0.canBecomeKey }) else {
            record("quick add panel opens and can become key", false, "no visible key-capable panel"); return
        }
        record("quick add panel opens and is the key window", panel.isKeyWindow, "key=\(panel.isKeyWindow) frame=\(Int(panel.frame.width))x\(Int(panel.frame.height))")
        let openFrame = panel.frame
        window = panel
        await typeText("Panel task > sub one")
        await waitStable { panel.frame }
        let (emptyFrame, typedFrame) = (openFrame, panel.frame)
        record("quick add panel hugs the card: shrinks while typing, top edge fixed",
               typedFrame.height < emptyFrame.height + 80 && abs(typedFrame.maxY - emptyFrame.maxY) < 1,
               "empty=\(Int(emptyFrame.height)) typed=\(Int(typedFrame.height)) topShift=\(Int(typedFrame.maxY - emptyFrame.maxY))")
        // A picture of the REAL panel (borderless: the content view is the whole window), so a
        // reviewer can confirm that nothing sits above the card. Path goes to the report.
        if let view = panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kronos-quickadd-panel.png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            diagnostics.append("panel picture: \(url.path) view=\(Int(view.bounds.width))x\(Int(view.bounds.height)) window=\(Int(panel.frame.width))x\(Int(panel.frame.height))")
        }
        key("\r", keyCode: 36)
        await waitUntil { store.allTasks().first { $0.title == "Panel task" }?.orderedSubtasks.count == 1 }
        let closedByReturn = await waitUntil(timeout: 2) { !panel.isVisible }
        record("quick add panel: Return adds and closes the panel", closedByReturn, "visible=\(panel.isVisible)")
        window = main
        let made = store.allTasks().first { $0.title == "Panel task" }
        record("quick add panel: typing, subtask",
               made?.orderedSubtasks.map(\.title) == ["sub one"],
               "subtasks=\(made?.orderedSubtasks.map(\.title) ?? []) status=\(String(describing: made?.status))")
        if panel.isVisible { AppDelegate.shared.quickAdd.toggle(); await waitUntil { !panel.isVisible } }
        await ensureKey(main)
    }
}
#endif
