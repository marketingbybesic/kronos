// Live steps for the project palette editor in Settings > Appearance > Advanced. Run alone with
// `--only group:F-OPEN`.
//  1. Every row's grip and both arrows are at least 24 x 24 pt.
//  2. The down arrow of the first row swaps it with the second (the order is read back from the preferences).
//  3. A real drag of the first row's grip, three rows down, shows the insertion line in the gap below the
//     fourth row while the button is held, and on release files the row there.
// The palette order is parked before the run and put back after it, in the hermetic defaults of the run.
#if !RELEASE
import AppKit
import SwiftUI
import KronosCore

/// A borderless window that can take key focus, so presses and drags reach the hosted controls.
private final class FOpenKeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

@MainActor
extension LiveUITest {

    private static let foPaletteKey = "kronos.appearance.paletteOrder"

    static func fOpenSteps(_ model: AppModel) async {
        let breakMode = ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil
        let priorOrder = KronosEnv.defaults.data(forKey: foPaletteKey)
        let priorScale = (DSScale.density, DSScale.text)
        let mainWindow: NSWindow = window
        defer {
            if let priorOrder { KronosEnv.defaults.set(priorOrder, forKey: foPaletteKey) } else { KronosEnv.defaults.removeObject(forKey: foPaletteKey) }
            DSScale.density = priorScale.0
            DSScale.text = priorScale.1
            model.didMutate()
            window = mainWindow
            mainWindow.makeKeyAndOrderFront(nil)
        }
        KronosEnv.defaults.removeObject(forKey: foPaletteKey)
        DSScale.apply(density: "regular", textSize: "L")
        model.didMutate()

        let host = NSHostingController(rootView: SettingsScreen(model: model, initialTab: .appearance).frame(width: 900, height: 1300).background(Tok.bg))
        let win = FOpenKeyableWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 1300), styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentViewController = host
        win.setContentSize(NSSize(width: 900, height: 1300))
        win.center()
        window = win
        defer { win.orderOut(nil) }
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        _ = await waitUntil(timeout: 5) { UITestAnchors.frames["settings.rail.appearance"] != nil }
        _ = await click("settings.rail.appearance")
        let header = "settings.disclosure.advanced.appearance"
        _ = await waitUntil(timeout: 4) { UITestAnchors.frames[header] != nil }
        await settle(300)
        await foScrollToEnd(win)
        _ = await click(header)
        _ = await waitUntil(timeout: 4) { UITestAnchors.frames["settings.appearance.palette"] != nil }
        await settle(300)
        await foScrollToEnd(win)

        let names = ProjectPalettePrefs.slots.map(\.baseName)
        await foTargets(names, breakMode: breakMode)
        await foArrow(names, breakMode: breakMode)
        // The drag starts from the order the arrow step left behind: the view holds it, the preferences store it.
        await foDrag(foOrder(), breakMode: breakMode)
        win.orderOut(nil)
    }

    private static func foScrollToEnd(_ win: NSWindow) async {
        func scrollViews(_ v: NSView) -> [NSScrollView] { (v as? NSScrollView).map { [$0] } ?? v.subviews.flatMap(scrollViews) }
        guard let content = win.contentView else { return }
        for sv in scrollViews(content) {
            guard let doc = sv.documentView else { continue }
            let y = doc.isFlipped ? max(0, doc.frame.height - sv.contentView.bounds.height) : 0
            sv.contentView.scroll(to: NSPoint(x: 0, y: y))
            sv.reflectScrolledClipView(sv.contentView)
        }
        await settle(350)
    }

    private static func foAnchors(_ kind: String, _ names: [String]) -> [String: CGRect] {
        Dictionary(uniqueKeysWithValues: names.compactMap { n in UITestAnchors.frames["settings.appearance.palette.\(kind).\(n)"].map { (n, $0) } })
    }

    private static func foOrder() -> [String] { ProjectPalettePrefs.slots.map(\.baseName) }

    // MARK: 1. hit targets

    private static func foTargets(_ names: [String], breakMode: Bool) async {
        let grips = foAnchors("grip", names), ups = foAnchors("up", names), downs = foAnchors("down", names)
        func small(_ frames: [String: CGRect]) -> [String] {
            // Break: ask for 30 pt, which the 24 pt controls cannot honour.
            let floor = breakMode ? 30 : Metrics.minHit
            return frames.filter { $0.value.width < floor || $0.value.height < floor }.keys.sorted()
        }
        record("every palette row has a grip and both arrows, each at least 24 x 24 pt",
               grips.count == names.count && ups.count == names.count && downs.count == names.count
                && small(grips).isEmpty && small(ups).isEmpty && small(downs).isEmpty,
               "rows=\(names.count) grips=\(grips.count) ups=\(ups.count) downs=\(downs.count) small=\(small(grips) + small(ups) + small(downs)) first=\(names.first.flatMap { grips[$0] }.map { "\(Int($0.width))x\(Int($0.height))" } ?? "nil")")
        // Positive control: the measure sees a 24 x 12 control as too small (what the arrows used to be).
        let old = CGRect(x: 0, y: 0, width: 24, height: 12)
        record("the target measure can fail: a 24 x 12 pt arrow counts as too small",
               (old.width < Metrics.minHit || old.height < Metrics.minHit) == !breakMode, "old=\(Int(old.width))x\(Int(old.height))")
    }

    // MARK: 2. arrow

    private static func foArrow(_ names: [String], breakMode: Bool) async {
        guard names.count >= 3 else { record("the palette has at least three rows", false, "rows=\(names.count)"); return }
        KronosEnv.defaults.removeObject(forKey: foPaletteKey)
        await settle(300)
        _ = await click("settings.appearance.palette.down.\(names[0])")
        let moved = await waitUntil(timeout: 3) { foOrder().prefix(2) == [names[1], names[0]] }
        // Hand-written: the first two swap, the rest keep their place.
        let want = [names[1], names[0]] + names.dropFirst(2)
        // Break: expect the first row to have stayed.
        record("the first row's down arrow swaps it with the second and leaves the rest",
               (breakMode ? foOrder() == names : (moved && foOrder() == want)),
               "order=\(foOrder().prefix(4)) want=\(want.prefix(4))")
    }

    // MARK: 3. drag

    private static func foDrag(_ names: [String], breakMode: Bool) async {
        guard names.count >= 5 else { record("the palette has at least five rows", false, "rows=\(names.count)"); return }
        await settle(500)
        let shownOrder = names.sorted { (UITestAnchors.frames["settings.appearance.palette.grip.\($0)"]?.minY ?? 0) < (UITestAnchors.frames["settings.appearance.palette.grip.\($1)"]?.minY ?? 0) }
        guard shownOrder == names else {
            record("the rows on screen are in the stored order before the drag", false, "shown=\(shownOrder.prefix(4)) stored=\(names.prefix(4))")
            return
        }
        guard let start = point("settings.appearance.palette.grip.\(names[0])"),
              let third = point("settings.appearance.palette.grip.\(names[3])") else {
            record("a palette grip can be dragged", false, "grip anchors missing")
            return
        }
        if !NSApp.isActive { lostFocus = true }
        post(.mouseMoved, at: start)
        post(.leftMouseDown, at: start)
        try? await Task.sleep(for: .milliseconds(80))
        // Move in steps down to the centre of the fourth row; hold there so the line can be measured.
        let steps = 8
        for i in 1...steps {
            let p = NSPoint(x: start.x, y: start.y + (third.y - start.y) * CGFloat(i) / CGFloat(steps))
            post(.leftMouseDragged, at: p)
            try? await Task.sleep(for: .milliseconds(40))
        }
        let shown = await waitUntil(timeout: 2) { UITestAnchors.frames["settings.appearance.palette.insertion"] != nil }
        let line = UITestAnchors.frames["settings.appearance.palette.insertion"]
        let g3 = UITestAnchors.frames["settings.appearance.palette.grip.\(names[3])"]
        let g4 = UITestAnchors.frames["settings.appearance.palette.grip.\(names[4])"]
        // The line sits in the gap between the fourth and the fifth row.
        let inGap = line.map { l in g3.map { l.midY > $0.midY } == true && g4.map { l.midY < $0.midY } == true } ?? false
        let wide = (line?.width ?? 0) > 100
        let stillOrdered = foOrder() == names
        post(.leftMouseUp, at: NSPoint(x: start.x, y: third.y))
        _ = await waitUntil(timeout: 3) { foOrder() != names }
        let after = foOrder()
        // Hand-written: the first row now sits fourth, rows two to four moved up by one.
        let want = [names[1], names[2], names[3], names[0]] + names.dropFirst(4)
        // Break: expect the order to be unchanged after the drag.
        record("while the first row is dragged three rows down the insertion line shows in the gap below the fourth row",
               shown && inGap && wide && stillOrdered,
               "shown=\(shown) inGap=\(inGap) wide=\(wide) orderUntouchedWhileHeld=\(stillOrdered) line=\(line.map { "\(Int($0.midY))/\(Int($0.width))" } ?? "nil") g3=\(g3.map { Int($0.midY) } ?? -1) g4=\(g4.map { Int($0.midY) } ?? -1)")
        record("letting go files the dragged row fourth and the line disappears",
               (breakMode ? after == names : after == want) && UITestAnchors.frames["settings.appearance.palette.insertion"] == nil,
               "after=\(after.prefix(5)) want=\(want.prefix(5))")
    }
}
#endif
