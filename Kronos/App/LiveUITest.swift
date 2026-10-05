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
        guard let path = env["KRONOS_UITEST"], !path.isEmpty, KronosEnv.isHermetic,
              env["KRONOS_STORE_DIR"]?.isEmpty == false else { return nil }
        // The test types and clicks for real: it must never run against the person's own store.
        guard !KronosEnv.storeDirectory.path.contains("/Library/Application Support/Kronos") else { return nil }
        return path
    }
    static var isRequested: Bool { reportPath != nil }

    static var steps: [[String: Any]] = []
    static var window: NSWindow!
    static var eventNumber = 0

    /// The fixed steps, in order. Each runs after `resetState`, so none depends on what the previous
    /// one left open or selected. Leaf steps are registered separately (LiveUITest+Registry.swift).
    static let topLevelSteps: [(name: String, run: @MainActor (AppModel) async -> Void)] = [
        ("scenario", scenario),
        ("keys", keysStep),
        ("paletteFits", paletteFits),
        ("paletteTypingAndKeymap", paletteTypingAndKeymap),
        ("hotkeyChord", hotkeyChordStep),
        ("fix3", fix3Step),
        ("inspectorSubtask", inspectorSubtaskStep),
        ("nesting", nestingStep),
        ("contextMenus", contextMenusStep),
        ("drop", dropStep),
        ("childRows", childRowsStep),
    ]

    static func run(model: AppModel) {
        guard let path = reportPath else { return }
        Task { @MainActor in
            // A tiling window manager floats this window a moment after launch (scripts/ui-test.mjs) and until
            // then re-imposes its tile size on every setFrame: give it that time before the first resize.
            await settle(2000)
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            @MainActor func mainWindow() -> NSWindow? {
                NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.canBecomeKey })
            }
            guard await waitUntil(timeout: 15, { mainWindow() != nil }), let win = mainWindow() else {
                finish(path, fatal: "no window"); return
            }
            window = win
            // The first frame still settles after the window appears: wait for the store-backed
            // content to publish its first anchor instead of sleeping a fixed time.
            await waitUntil(timeout: 10, { !UITestAnchors.frames.isEmpty })
            win.makeKeyAndOrderFront(nil)
            await waitUntil(timeout: 5, { NSApp.isActive && win.isKeyWindow })
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
            await ensureKey(win)
            let only = ProcessInfo.processInfo.environment["KRONOS_UITEST_ONLY"]
            if only == "children" {
                await runStep(model, scope: .all, childRowsStep)
                finish(path, fatal: nil)
                return
            }
            if only == "scenario" {
                await runStep(model, scope: .all, scenario)
                finish(path, fatal: nil)
                return
            }
            if let only, only.hasPrefix("group:") {
                for n in String(only.dropFirst(5)).split(separator: ",").map(String.init) {
                    if n == "contextmenus" { await runStep(model, scope: .all, contextMenusStep); continue }
                    await runStep(model) { await runLeafSteps($0, only: n) }
                }
                finish(path, fatal: nil)
                return
            }
            // The fixed steps were written against the All list (the state the scenario leaves behind).
            for step in topLevelSteps { await runStep(model, scope: .all, step.run) }
            // Each registered leaf step gets the same reset as the steps above.
            for leaf in leafSteps { await runStep(model) { await runLeafSteps($0, only: leaf.name) } }
            finish(path, fatal: nil)
        }
    }


    /// 7. The palette card is fully inside the window at the smallest size the window allows (its left edge used to be cut off).
    static func paletteFits(_ model: AppModel) async {
        var frame = window.frame
        frame.size = NSSize(width: 640, height: 760)
        window.setFrame(frame, display: true)
        await waitStable { window.frame.size }
        model.isPaletteOpen = true
        await waitUntil(timeout: 4) { UITestAnchors.frames["palette.card"] != nil }
        await waitStable { UITestAnchors.frames["palette.card"] ?? .zero }
        let card = UITestAnchors.frames["palette.card"]
        let width = window.contentView?.bounds.width ?? 0
        let ok = card.map { $0.minX >= 8 && $0.maxX <= width - 8 && $0.width > 300 } ?? false
        record("palette card is fully inside the window at its minimum width", ok, "card=\(card.map { "\(Int($0.minX))...\(Int($0.maxX))" } ?? "nil") window=\(Int(width))")
        model.isPaletteOpen = false
    }

    // MARK: Report

    static func record(_ name: String, _ pass: Bool, _ detail: String) {
        steps.append(["name": name, "pass": pass, "detail": detail])
        if let h = FileHandle(forWritingAtPath: "/tmp/kronos-uitest-progress.log") ?? { FileManager.default.createFile(atPath: "/tmp/kronos-uitest-progress.log", contents: nil); return FileHandle(forWritingAtPath: "/tmp/kronos-uitest-progress.log") }() {
            h.seekToEndOfFile(); h.write(Data("\(pass ? "ok" : "FAIL") \(name)\n".utf8)); try? h.close()
        }
    }

    static func finish(_ path: String, fatal fatalIn: String?) {
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
