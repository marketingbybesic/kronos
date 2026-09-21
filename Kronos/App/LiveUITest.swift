// Live UI test: `KRONOS_UITEST=<report.json>` + `KRONOS_STORE_DIR=<scratch>` makes the REAL app
// click and type on itself (synthetic NSEvents posted to its own queue: no Accessibility permission
// needed, nothing outside this process is touched) and asserts on MODEL STATE.
// Why it exists: three rounds of snapshots were green while clicks, keys and Cmd-Z were dead.
// A snapshot proves render; only this proves interaction. `KRONOS_UITEST_BREAK=1` flips one
// expectation so the run must fail: the proof that this judge can say no.
import AppKit
import SwiftUI
import KronosCore

// Release stub: `isRequested`/`run` are only ever called from AppDelegate.swift, already
// behind `#if !RELEASE` there — but the type itself must still exist and compile so that file
// compiles in every config. The real implementation (which posts synthetic NSEvents, drives
// task titles like "Plan trip" through the app, and writes a JSON report) is compiled out
// entirely, so none of its code or fixture strings reach the linked Release binary.
#if RELEASE
@MainActor
enum LiveUITest {
    static var isRequested: Bool { false }
    static func run(model: AppModel) {}
}
#else
@MainActor
enum LiveUITest {
    static var reportPath: String? {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["KRONOS_UITEST"], !path.isEmpty, let dir = env["KRONOS_STORE_DIR"], !dir.isEmpty else { return nil }
        return path
    }
    static var isRequested: Bool { reportPath != nil }

    static var steps: [[String: Any]] = []
    static var window: NSWindow!
    static var eventNumber = 0

    static func run(model: AppModel) {
        guard let path = reportPath else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            guard let win = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.canBecomeKey }) else {
                finish(path, fatal: "no window"); return
            }
            window = win
            win.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(800))
            // An inactive app spends its first click on activation: that would fake the very bug
            // this test hunts. Refuse to judge unless the window really is key.
            guard NSApp.isActive, win.isKeyWindow else {
                finish(path, fatal: "test window is not active/key (active=\(NSApp.isActive) key=\(win.isKeyWindow)): cannot judge clicks"); return
            }
            // Positive control: a trivial SwiftUI Button in a window of our own. If a synthetic click
            // cannot press THAT, the mechanism is broken and nothing below may be read as an app bug.
            guard await controlClickWorks() else {
                finish(path, fatal: "positive control failed: synthetic clicks do not press a plain SwiftUI Button"); return
            }
            window = win
            win.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(500))
            await scenario(model)
            await paletteFits(model)
            await hotkeyChordStep(model)
            finish(path, fatal: nil)
        }
    }

    // MARK: Scenario

    private static func scenario(_ model: AppModel) async {
        let breakMode = ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil
        let store = model.store

        // 1. One click on a sidebar list switches the list. Timed: a prior report was of lag here.
        for (label, scope) in [("Waiting", ListScope.waiting), ("Someday", .someday), ("All", .all)] {
            let t0 = Date()
            let found = await click("sidebar." + label)
            try? await Task.sleep(for: .milliseconds(350))
            let want: ListScope = (breakMode && label == "Waiting") ? .inbox : scope
            record("sidebar one click -> \(label)", found && model.scope == want,
                   "found=\(found) scope=\(model.scope) ms=\(Int(Date().timeIntervalSince(t0) * 1000))")
        }

        // 2. One click on a row selects it.
        let open = store.allTasks().filter { KStatus.open.contains($0.status) }
        guard let target = open.first(where: { ($0.subtasks ?? []).isEmpty }) else { record("has a plain task", false, ""); return }
        var ok = await click("row." + target.title, xFraction: 0.45)
        try? await Task.sleep(for: .milliseconds(300))
        record("row one click selects", ok && model.selectedTaskID == target.id, "found=\(ok) selected=\(String(describing: model.selectedTaskID))")

        // 3. Keys right after that click, no second click: 3 sets priority, 0 clears it.
        key("3"); try? await Task.sleep(for: .milliseconds(250))
        record("key 3 sets priority high", store.task(target.id)?.priority == .high, "\(String(describing: store.task(target.id)?.priority))")
        let wasHigh = store.task(target.id)?.priority == .high
        key("0"); try? await Task.sleep(for: .milliseconds(250))
        record("key 0 clears priority", wasHigh && store.task(target.id)?.priority == KPriority.none, "\(String(describing: store.task(target.id)?.priority))")

        // 4. Clicking the circle completes; Cmd-Z brings it back (no 5 s limit: we wait 6).
        ok = await click("row." + target.title, xOffset: 6 + Metrics.listRowLeading + Metrics.listCheckboxSize / 2)
        try? await Task.sleep(for: .milliseconds(400))
        record("circle click completes", ok && store.task(target.id)?.status == .done, "found=\(ok) status=\(String(describing: store.task(target.id)?.status))")
        let wasDone = store.task(target.id)?.status == .done
        try? await Task.sleep(for: .seconds(6))
        key("z", modifiers: .command, keyCode: 6); try? await Task.sleep(for: .milliseconds(400))
        if store.task(target.id)?.status == .done {
            // Separate "the command is broken" from "my synthetic key never reached the menu".
            let item = undoMenuItem()
            diagnostics.append("undo item: \(item.map { "'\($0.title)' enabled=\($0.isEnabled) key=\($0.keyEquivalent) mods=\($0.keyEquivalentModifierMask.rawValue)" } ?? "NOT FOUND") canUndo=\(store.canUndo)")
            if let item, let menu = item.menu { menu.performActionForItem(at: menu.index(of: item)) }
            try? await Task.sleep(for: .milliseconds(400))
            diagnostics.append("after performing the Undo menu item directly: status=\(String(describing: store.task(target.id)?.status))")
        }
        record("Undo after 6 s reopens (Cmd-Z key, else the enabled Undo menu item)", wasDone && store.task(target.id)?.status == .todo, "status=\(String(describing: store.task(target.id)?.status))")

        // 5. The subtask arrow lists the subtasks.
        if let parent = open.first(where: { !($0.subtasks ?? []).isEmpty }), let sub = parent.orderedSubtasks.first {
            let before = UITestAnchors.frames["subrow." + sub.title] != nil
            ok = await click("arrow." + parent.title)
            try? await Task.sleep(for: .milliseconds(500))
            let after = UITestAnchors.frames["subrow." + sub.title] != nil
            record("subtask arrow expands", ok && !before && after, "found=\(ok) before=\(before) after=\(after)")
            // 5b. E closes and reopens every subtask list (row selected first, so the list has the keys).
            _ = await click("row." + target.title, xFraction: 0.45)
            try? await Task.sleep(for: .milliseconds(300))
            key("e"); try? await Task.sleep(for: .milliseconds(500))
            let openAll = UITestAnchors.frames["subrow." + sub.title] != nil
            key("e"); try? await Task.sleep(for: .milliseconds(500))
            let closedAll = UITestAnchors.frames["subrow." + sub.title] == nil
            record("E opens then closes all subtasks", openAll && closedAll, "open=\(openAll) closed=\(closedAll)")
        } else { record("has a task with subtasks", false, "") }

        // 6. Inline new task: click the field, type WITH spaces and syntax, Return.
        let countBefore = store.allTasks().count
        ok = await click("inlineadd.field", xFraction: 0.3)
        try? await Task.sleep(for: .milliseconds(300))
        diagnostics.append("after clicking the inline field: firstResponder=\(window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")")
        diagnostics.append("isTyping inputs: keyWindowIsMain=\(NSApp.keyWindow === window) keyWindow=\(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "nil") frIsTextView=\(window.firstResponder is NSTextView) keyFrIsTextView=\(NSApp.keyWindow?.firstResponder is NSTextView)")
        for ch in "Buy oat milk !! tomorrow" { key(String(ch)); try? await Task.sleep(for: .milliseconds(25)) }
        diagnostics.append("typed into the field: \"\((window.firstResponder as? NSTextView)?.string ?? "<not a text view>")\"")
        key("\r", keyCode: 36); try? await Task.sleep(for: .milliseconds(500))
        diagnostics.append("after Return: field=\"\((window.firstResponder as? NSTextView)?.string ?? "<none>")\" responder=\(window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")")
        let made = store.allTasks().first { $0.title == "Buy oat milk" }
        record("inline add: spaces, syntax, Return", ok && store.allTasks().count == countBefore + 1 && made?.priority == .medium
               && made?.dueDay == Day.today(calendar: KronosLocale.calendar) + 1,
               "found=\(ok) count=\(store.allTasks().count - countBefore) title=\(made?.title ?? "nil") prio=\(String(describing: made?.priority)) due=\(String(describing: made?.dueDay))")

        // 6b. Subtasks from the same field: "Task > sub > sub" makes one task with two subtasks.
        for ch in "Plan trip > book flight > book hotel" { key(String(ch)); try? await Task.sleep(for: .milliseconds(25)) }
        key("\r", keyCode: 36); try? await Task.sleep(for: .milliseconds(500))
        let trip = store.allTasks().first { $0.title == "Plan trip" }
        record("inline add: Task > sub > sub", trip?.orderedSubtasks.map(\.title) == ["book flight", "book hotel"],
               "subtasks=\(trip?.orderedSubtasks.map(\.title) ?? [])")

        await triageKeys(model, leaveFieldBy: "row." + target.title)
        await quickAddPanelTypes(model)
        await noteLinkButton(model)
    }

    /// 9. The global quick add panel is a borderless NSPanel: it must still become KEY and take
    /// typing (a plain borderless panel cannot), create subtasks, and file an undated task in Someday.
    private static func quickAddPanelTypes(_ model: AppModel) async {
        let store = model.store
        let main = window!
        AppDelegate.shared.quickAdd.toggle()
        try? await Task.sleep(for: .milliseconds(900))
        guard let panel = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible && $0 !== main && $0.canBecomeKey }) else {
            record("quick add panel opens and can become key", false, "no visible key-capable panel"); return
        }
        record("quick add panel opens and is the key window", panel.isKeyWindow, "key=\(panel.isKeyWindow) frame=\(Int(panel.frame.width))x\(Int(panel.frame.height))")
        let openFrame = panel.frame
        window = panel
        for ch in "Panel task > sub one" { key(String(ch)); try? await Task.sleep(for: .milliseconds(25)) }
        try? await Task.sleep(for: .milliseconds(400))
        let (emptyFrame, typedFrame) = (openFrame, panel.frame)
        record("quick add panel hugs the card: shrinks while typing, top edge fixed",
               typedFrame.height < emptyFrame.height - 100 && abs(typedFrame.maxY - emptyFrame.maxY) < 1,
               "empty=\(Int(emptyFrame.height)) typed=\(Int(typedFrame.height)) topShift=\(Int(typedFrame.maxY - emptyFrame.maxY))")
        // A picture of the REAL panel (borderless: the content view is the whole window), so a
        // reviewer can confirm that nothing sits above the card. Path goes to the report.
        if let view = panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kronos-quickadd-panel.png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            diagnostics.append("panel picture: \(url.path) view=\(Int(view.bounds.width))x\(Int(view.bounds.height)) window=\(Int(panel.frame.width))x\(Int(panel.frame.height))")
        }
        key("\r", keyCode: 36); try? await Task.sleep(for: .milliseconds(700))
        window = main
        let made = store.allTasks().first { $0.title == "Panel task" }
        record("quick add panel: typing, subtask, undated -> Someday",
               made?.orderedSubtasks.map(\.title) == ["sub one"] && made?.status == .someday,
               "subtasks=\(made?.orderedSubtasks.map(\.title) ?? []) status=\(String(describing: made?.status))")
        if panel.isVisible { AppDelegate.shared.quickAdd.toggle(); try? await Task.sleep(for: .milliseconds(400)) }
        main.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(400))
    }

    /// 8. Triage card keys (reported dead twice). Digits write the CURRENT card's priority, so which
    /// task changed tells us whether Tab and Return really moved on. Expected tasks are derived here
    /// from the store, not read back from the card.
    private static func triageKeys(_ model: AppModel, leaveFieldBy rowID: String) async {
        let store = model.store
        _ = await click(rowID, xFraction: 0.45)          // leave the inline text field
        try? await Task.sleep(for: .milliseconds(300))
        var seen: [UUID] = []
        func next() -> KTask? { TriageQueue.ordered(in: store.allTasks()).first { !seen.contains($0.id) } }
        guard let first = next() else { record("triage has a queue", false, ""); return }
        model.isTriageOpen = true
        try? await Task.sleep(for: .milliseconds(900))
        record("triage card is on screen", UITestAnchors.frames["triage.card"] != nil, "")

        key("4"); try? await Task.sleep(for: .milliseconds(300))
        record("triage key 4 sets urgent on the first card", store.task(first.id)?.priority == .urgent, "\(String(describing: store.task(first.id)?.priority))")
        // A second field key must keep the first value instead of overwriting it.
        key("s"); try? await Task.sleep(for: .milliseconds(600))
        record("triage key s sets effort and KEEPS the urgent priority",
               store.task(first.id)?.effort == .s && store.task(first.id)?.priority == .urgent,
               "effort=\(String(describing: store.task(first.id)?.effort)) priority=\(String(describing: store.task(first.id)?.priority))")

        seen.append(first.id)
        key("\t", keyCode: 48); try? await Task.sleep(for: .milliseconds(400))
        guard let second = next() else { record("triage has a second task", false, ""); return }
        key("3"); try? await Task.sleep(for: .milliseconds(300))
        record("triage Tab skips to the next card", store.task(second.id)?.priority == .high && store.task(first.id)?.priority == .urgent,
               "second=\(String(describing: store.task(second.id)?.priority)) first=\(String(describing: store.task(first.id)?.priority))")

        seen.append(second.id)
        key("\r", keyCode: 36); try? await Task.sleep(for: .milliseconds(500))
        guard let third = next() else { record("triage has a third task", false, ""); return }
        key("2"); try? await Task.sleep(for: .milliseconds(300))
        record("triage Return accepts and moves on", store.task(third.id)?.priority == .medium && store.task(second.id)?.priority == .high,
               "third=\(String(describing: store.task(third.id)?.priority)) second=\(String(describing: store.task(second.id)?.priority))")

        key("\u{1B}", keyCode: 53); try? await Task.sleep(for: .milliseconds(400))
        record("triage Esc closes", !model.isTriageOpen, "open=\(model.isTriageOpen)")
    }

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

    private final class Flag { var pressed = false }

    private static func pressed<V: View>(_ name: String, _ make: (Flag) -> V) async -> Bool {
        let flag = Flag()
        let host = NSHostingView(rootView: make(flag).frame(width: 240, height: 100).background(Color.black))
        let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 100), styleMask: [.titled],
                         backing: .buffered, defer: false)
        w.contentView = host
        w.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(500))
        let main = window
        window = w
        await clickPoint(NSPoint(x: 120, y: 50))
        try? await Task.sleep(for: .milliseconds(400))
        window = main
        w.orderOut(nil)
        record("control: \(name)", flag.pressed, "pressed=\(flag.pressed)")
        return flag.pressed
    }

    private static func controlClickWorks() async -> Bool {
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

    /// 7. The palette card is fully inside the window at the smallest size the window allows (its left edge used to be cut off).
    private static func paletteFits(_ model: AppModel) async {
        var frame = window.frame
        frame.size = NSSize(width: 640, height: 760)
        window.setFrame(frame, display: true)
        try? await Task.sleep(for: .milliseconds(500))
        model.isPaletteOpen = true
        try? await Task.sleep(for: .milliseconds(700))
        let card = UITestAnchors.frames["palette.card"]
        let width = window.contentView?.bounds.width ?? 0
        let ok = card.map { $0.minX >= 8 && $0.maxX <= width - 8 && $0.width > 300 } ?? false
        record("palette card is fully inside the window at its minimum width", ok, "card=\(card.map { "\(Int($0.minX))...\(Int($0.maxX))" } ?? "nil") window=\(Int(width))")
        model.isPaletteOpen = false
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
        guard let p = point(id, xFraction: xFraction, xOffset: xOffset) else { return false }
        let hit = window.contentView?.hitTest(window.contentView!.convert(p, from: nil))
        diagnostics.append("\(id): win=(\(Int(p.x)),\(Int(p.y))) active=\(NSApp.isActive) key=\(window.isKeyWindow) hit=\(hit.map { String(describing: type(of: $0)) } ?? "nil") content=\(Int(window.contentView!.bounds.height)) flipped=\(window.contentView!.isFlipped)")
        await clickPoint(p)
        return true
    }

    // MARK: Report

    static func record(_ name: String, _ pass: Bool, _ detail: String) {
        steps.append(["name": name, "pass": pass, "detail": detail])
    }

    private static func finish(_ path: String, fatal fatalIn: String?) {
        let fatal = fatalIn ?? (lostFocus ? "INCONCLUSIVE: the test app lost focus mid-run (someone used the Mac); run it again" : nil)
        var report: [String: Any] = ["steps": steps, "passed": steps.filter { $0["pass"] as? Bool == true }.count,
                                     "failed": steps.filter { $0["pass"] as? Bool != true }.count]
        if let fatal { report["fatal"] = fatal }
        report["diagnostics"] = diagnostics
        report["anchors"] = UITestAnchors.frames.keys.sorted().prefix(60).map { $0 }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        NSApp.terminate(nil)
    }
}
#endif
