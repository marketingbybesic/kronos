// Kronos/App/LiveUITest+Support.swift
// Shared helpers of the live test: positive control, synthetic events, anchors lookup, waiting, reporting.
#if !RELEASE
import AppKit
import SwiftUI
import KronosCore

@MainActor
extension LiveUITest {
    static func undoMenuItem() -> NSMenuItem? {
        func find(_ menu: NSMenu?) -> NSMenuItem? {
            for item in menu?.items ?? [] {
                if item.keyEquivalent.lowercased() == "z", item.keyEquivalentModifierMask == .command { return item }
                if let hit = find(item.submenu) { return hit }
            }
            return nil
        }
        return find(NSApp.mainMenu)
    }

    // MARK: Positive control

    final class Flag { var pressed = false }

    static func pressed<V: View>(_ name: String, _ make: (Flag) -> V) async -> Bool {
        let flag = Flag()
        let host = NSHostingView(rootView: make(flag).frame(width: 240, height: 100).background(Color.black))
        let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 100), styleMask: [.titled],
                         backing: .buffered, defer: false)
        w.contentView = host
        w.makeKeyAndOrderFront(nil)
        await waitUntil(timeout: 3) { NSApp.isActive && w.isKeyWindow }
        await waitStable { host.frame }
        await settle(300)
        let main = window
        window = w
        await clickPoint(NSPoint(x: 120, y: 50))
        // A click on a view that is still mounting can be lost: one retry, only when nothing was pressed.
        if !(await waitUntil(timeout: 1.5, { flag.pressed })) {
            await ensureKey(w)
            await clickPoint(NSPoint(x: 120, y: 50))
            await waitUntil(timeout: 1.5) { flag.pressed }
        }
        window = main
        w.orderOut(nil)
        record("control: \(name)", flag.pressed, "pressed=\(flag.pressed)")
        return flag.pressed
    }

    static func controlClickWorks() async -> Bool {
        let plain = await pressed("plain Button") { f in Button("control") { f.pressed = true }.frame(width: 240, height: 100).contentShape(Rectangle()) }
        // Diagnostic variants: they narrow down WHICH layer of the sidebar row eats the click.
        _ = await pressed("plain Button in ScrollView") { f in
            ScrollView { Button("control") { f.pressed = true }.frame(width: 240, height: 100).contentShape(Rectangle()) }
        }
        _ = await pressed("KSidebarRow alone") { f in
            KSidebarRow(title: "ctl", leadingIcon: "sun") { f.pressed = true }.frame(height: 100)
        }
        _ = await pressed("KSidebarRow in ScrollView") { f in
            ScrollView { KSidebarRow(title: "ctl", leadingIcon: "sun") { f.pressed = true }.frame(height: 100) }
        }
        _ = await pressed("Button + accessibilityElement(children: .ignore)") { f in
            Button("control") { f.pressed = true }.buttonStyle(.plain).frame(width: 240, height: 100).contentShape(Rectangle())
                .accessibilityElement(children: .ignore).accessibilityLabel("x")
        }
        return plain
    }

    // MARK: Events

    static func post(_ type: NSEvent.EventType, at p: NSPoint) {
        eventNumber += 1
        if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber,
                                      clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
            NSApp.postEvent(e, atStart: false)
        }
    }

    /// Set when the app stopped being frontmost mid-run (someone is using the Mac): results after
    /// that are not evidence, so the run ends INCONCLUSIVE instead of reporting a false failure.
    static var lostFocus = false

    static func clickPoint(_ p: NSPoint) async {
        if !NSApp.isActive { lostFocus = true }
        post(.mouseMoved, at: p)
        post(.leftMouseDown, at: p)
        try? await Task.sleep(for: .milliseconds(60))
        post(.leftMouseUp, at: p)
    }

    static func key(_ chars: String, modifiers: NSEvent.ModifierFlags = [], keyCode: UInt16 = 0) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, characters: chars,
                                        charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode) {
                NSApp.postEvent(e, atStart: false)
            }
        }
    }

    // MARK: Finding things (frames the views report themselves: DesignSystem/UITestAnchors.swift)

    /// Window coordinates (bottom-left origin) of a point inside the anchored view.
    static func point(_ id: String, xFraction: CGFloat = 0.5, xOffset: CGFloat? = nil) -> NSPoint? {
        guard let f = UITestAnchors.frames[id], f.width > 1, let content = window.contentView else { return nil }
        let x = xOffset.map { f.minX + $0 } ?? f.minX + f.width * xFraction
        // SwiftUI's global space is the content view's own top-left space; let AppKit do the flip.
        let local = content.isFlipped ? NSPoint(x: x, y: f.midY) : NSPoint(x: x, y: content.bounds.height - f.midY)
        return content.convert(local, to: nil)
    }

    static var diagnostics: [String] = []

    static func click(_ id: String, xFraction: CGFloat = 0.5, xOffset: CGFloat? = nil) async -> Bool {
        // The view may still be mounting (lazy list, just-opened overlay): wait for its anchor, and for
        // the window to be key, so a click is never judged against a half-built or backgrounded UI.
        if UITestAnchors.frames[id] == nil { await waitUntil(timeout: 2) { UITestAnchors.frames[id] != nil } }
        await ensureKey(lenient: true)
        guard let p = point(id, xFraction: xFraction, xOffset: xOffset) else { return false }
        let hit = window.contentView?.hitTest(window.contentView!.convert(p, from: nil))
        diagnostics.append("\(id): win=(\(Int(p.x)),\(Int(p.y))) active=\(NSApp.isActive) key=\(window.isKeyWindow) hit=\(hit.map { String(describing: type(of: $0)) } ?? "nil") content=\(Int(window.contentView!.bounds.height)) flipped=\(window.contentView!.isFlipped)")
        await clickPoint(p)
        return true
    }

    // MARK: Waiting, focus, reset

    /// Polls `condition` every 20 ms until it holds or `timeout` seconds pass. Replaces a fixed sleep
    /// before an assertion: it returns as soon as the state is right (fast on a quiet Mac) and still
    /// waits long enough on a slow one, so the verdict stops depending on timing.
    @discardableResult
    static func waitUntil(timeout: TimeInterval = 3, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if condition() { return true }
            if Date() >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Returns once `read()` has stayed unchanged for 150 ms (an animation or relayout finished), or
    /// after `timeout` seconds. For measurements of a settled size or position.
    static func waitStable<T: Equatable>(timeout: TimeInterval = 2, _ read: @MainActor () -> T) async {
        let deadline = Date().addingTimeInterval(timeout)
        var last = read()
        var since = Date()
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(30))
            let now = read()
            if now != last { last = now; since = Date() }
            else if Date().timeIntervalSince(since) > 0.15 { return }
        }
    }

    /// Resizes the test window and checks the size stuck (a tiling window manager can put its tile
    /// size back); retries a few times, then records the size it got in the diagnostics.
    static func setWindowSize(width: CGFloat, height: CGFloat) async {
        for _ in 0..<5 {
            var frame = window.frame
            frame.size = NSSize(width: width, height: height)
            window.setFrame(frame, display: true)
            await waitStable { window.frame.size }
            if abs(window.frame.width - width) < 2 { return }
            await settle(600)
        }
        diagnostics.append("setWindowSize: wanted \(Int(width))x\(Int(height)), window is \(Int(window.frame.width))x\(Int(window.frame.height))")
    }

    /// Types `text` one character at a time, like a keyboard.
    static func typeText(_ text: String) async {
        for ch in text { key(String(ch)); await settle(25) }
    }

    /// A short fixed pause for the one case a condition cannot express: "nothing happened" (a key that
    /// must be ignored, a click that must not select). Everything else uses `waitUntil`.
    static func settle(_ ms: Int = 500) async {
        try? await Task.sleep(for: .milliseconds(ms))
    }

    /// The app is active and the window is key. Re-activates once if not; when it still is not (the
    /// person took the Mac), marks the run INCONCLUSIVE instead of letting later clicks fail as false
    /// app bugs. `lenient` accepts any key window of this app (a sheet or panel on top of `win`) and
    /// only insists that the app itself is active.
    @discardableResult
    static func ensureKey(_ win: NSWindow? = nil, lenient: Bool = false) async -> Bool {
        let target = win ?? window!
        func ok() -> Bool { NSApp.isActive && (target.isKeyWindow || (lenient && NSApp.keyWindow != nil)) }
        if ok() { return true }
        NSApp.activate(ignoringOtherApps: true)
        if !lenient { target.makeKeyAndOrderFront(nil) }
        if await waitUntil(timeout: 3, { ok() }) { return true }
        lostFocus = true
        diagnostics.append("ensureKey: not key (active=\(NSApp.isActive) key=\(target.isKeyWindow) appKey=\(NSApp.keyWindow != nil))")
        return false
    }

    /// Puts the app in a known state before a step: no overlay or panel open, no text field editing,
    /// no selection, search cleared, the Today list showing, the main window key. Steps that need
    /// another state set it themselves, so a failure in one step cannot leak into the next.
    static func resetState(_ model: AppModel, scope: ListScope = .today) async {
        let main = window!
        if let panel = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible && $0 !== main && $0.canBecomeKey }) {
            AppDelegate.shared.quickAdd.toggle()
            await waitUntil(timeout: 2, { !panel.isVisible })
        }
        window = main
        model.isPaletteOpen = false
        model.isTriageOpen = false
        model.isImpulsOpen = false
        model.isTimeBlocksOpen = false
        model.isKeymapOpen = false
        model.noteLinkPickerOpen = false
        model.isCaptureOpen = false
        model.pendingCaptureText = nil
        model.searchText = ""
        model.selectedTaskID = nil
        model.selectedIDs = []
        model.inspectedSubtaskID = nil
        model.scope = scope
        if main.firstResponder is NSTextView { main.makeFirstResponder(nil) }
        await ensureKey(main)
        await settle(150)
    }

    /// Runs one named step: reset, then the step, so every step starts from the same state.
    static func runStep(_ model: AppModel, scope: ListScope = .today, _ body: @MainActor (AppModel) async -> Void) async {
        await resetState(model, scope: scope)
        await body(model)
    }
}
#endif
