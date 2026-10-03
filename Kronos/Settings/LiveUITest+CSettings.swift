// Live steps for the Settings tabs. Run alone with `--only group:C-SETTINGS`.
//  1. The rail lists at most eight tabs, none of the merged ones, each a real hit target, and
//     no tab title is cut off in English or Croatian at text size L (measured against the label's
//     own frame; a control string that is too long proves the measure can fail).
//  2. Advanced (General, Appearance, Planning) starts closed, a press opens it and shows the
//     rarely changed preferences, a second press closes it; "Manual setup" does the same for the
//     MCP snippets while "Connect all" stays visible.
//  3. The Advanced header answers the keyboard: Space and Return open and close it.
//  4. The AI tab states what is sent to the model; the provider picker lists the named providers
//     plus Other; House rules shows its purpose line when empty; the last pane is remembered.
#if !RELEASE
import AppKit
import SwiftUI
import KronosCore

/// A borderless window that can take key focus, so presses and keys reach the hosted controls.
private final class SettingsKeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

@MainActor
extension LiveUITest {

    private static let csLastTabKey = "kronos.settings.lastTab"

    static func cSettingsSteps(_ model: AppModel) async {
        let breakMode = ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil
        let priorTab = KronosEnv.defaults.object(forKey: csLastTabKey)
        let priorScale = (DSScale.density, DSScale.text)
        let mainWindow: NSWindow = window
        defer {
            if let priorTab { KronosEnv.defaults.set(priorTab, forKey: csLastTabKey) } else { KronosEnv.defaults.removeObject(forKey: csLastTabKey) }
            DSScale.density = priorScale.0
            DSScale.text = priorScale.1
            model.didMutate()
            window = mainWindow
            mainWindow.makeKeyAndOrderFront(nil)
        }

        // Text size L, the size the person runs.
        DSScale.apply(density: "regular", textSize: "L")
        model.didMutate()

        let win = csWindow(NSHostingController(rootView:
            SettingsScreen(model: model, initialTab: .general).frame(width: 900, height: 1100).background(Tok.bg)),
            width: 900, height: 1100)
        window = win
        defer { win.orderOut(nil) }
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        _ = await waitUntil(timeout: 5) { UITestAnchors.frames["settings.rail.general"] != nil }
        await settle(400)

        csRail(breakMode: breakMode)
        await csRailFits(breakMode: breakMode)
        await csDisclosure(tab: "general", probes: ["settings.general.soundcues"], breakMode: breakMode)
        await csDisclosure(tab: "appearance", probes: ["settings.appearance.carriers.focusrow", "settings.appearance.palette"], breakMode: breakMode)
        await csDisclosure(tab: "planning", probes: ["settings.planning.presets"], breakMode: breakMode)
        await csAIEgressAndProviders(breakMode: breakMode)
        await csManualSetup(breakMode: breakMode)
        await csEmptyRules(model, breakMode: breakMode)
        await csLastPane(breakMode: breakMode)
        win.orderOut(nil)

        await csKeyboard(breakMode: breakMode)
    }

    private static func csWindow(_ host: NSViewController, width: CGFloat, height: CGFloat) -> NSWindow {
        let w = SettingsKeyableWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentViewController = host
        w.setContentSize(NSSize(width: width, height: height))
        w.center()
        return w
    }

    // MARK: 1. rail

    private static func csRail(breakMode: Bool) {
        let ids = SettingsTab.allCases.map(\.rawValue)
        let expected = ["general", "appearance", "planning", "ai", "mcp", "data", "shortcuts"]
        let merged = ["coach", "ordo", "notes", "about"]
        // Break: ask for at most six tabs, which the rail cannot honour.
        let cap = breakMode ? 6 : 8
        record("the Settings rail has at most eight tabs, all of the expected ones and none of the merged ones",
               ids.count <= cap && expected.allSatisfy(ids.contains) && merged.allSatisfy { !ids.contains($0) },
               "tabs=\(ids)")
        let rows = ids.compactMap { id in UITestAnchors.frames["settings.rail." + id].map { (id, $0) } }
        let small = rows.filter { $0.1.width < Metrics.minHit || $0.1.height < Metrics.minHit }.map(\.0)
        record("every rail row is on screen and at least 24 x 24 pt", rows.count == ids.count && small.isEmpty,
               "rows=\(rows.count)/\(ids.count) small=\(small)")
    }

    /// Title width at the real font against the frame the label gets in the rail.
    private static func csTitleFits(_ title: String, slot: CGFloat) -> Bool {
        let probe = NSHostingView(rootView: Text(verbatim: title).font(Typo.row).lineLimit(1).fixedSize())
        return probe.fittingSize.width <= slot
    }

    private static func csRailFits(breakMode: Bool) async {
        var cut: [String] = []
        var missing: [String] = []
        for lang in ["en", "hr"] {
            guard let path = Bundle.main.path(forResource: lang, ofType: "lproj"), let bundle = Bundle(path: path) else {
                missing.append(lang)
                continue
            }
            for tab in SettingsTab.allCases {
                guard let slot = UITestAnchors.frames["settings.rail.label." + tab.rawValue]?.width else {
                    missing.append(tab.rawValue)
                    continue
                }
                let title = bundle.localizedString(forKey: tab.titleKey, value: "§missing§", table: nil)
                if title == "§missing§" { missing.append(lang + ":" + tab.titleKey); continue }
                if !csTitleFits(title, slot: slot) { cut.append("\(lang):\(title)") }
            }
        }
        record("no rail tab title is cut off in English or Croatian at text size L", cut.isEmpty && missing.isEmpty,
               "cut=\(cut) missing=\(missing)")
        // Positive control: a title far longer than any tab must not fit the slot.
        let control = "Pružatelj usluga umjetne inteligencije i pristupa podacima"
        let slot = UITestAnchors.frames["settings.rail.label.general"]?.width ?? 0
        // Break: claim the control fits.
        record("the fit measure can fail: a 58 character title does not fit the rail label",
               csTitleFits(control, slot: slot) == breakMode, "slot=\(Int(slot)) control fits=\(csTitleFits(control, slot: slot))")
    }

    // MARK: 2. disclosures

    /// Scrolls the Settings pane to its end so a header below the window bottom can be pressed.
    private static func csScrollToEnd(_ win: NSWindow) async {
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

    private static func csAllPresent(_ ids: [String]) -> Bool { ids.allSatisfy { UITestAnchors.frames[$0] != nil } }
    private static func csAllAbsent(_ ids: [String]) -> Bool { ids.allSatisfy { UITestAnchors.frames[$0] == nil } }

    private static func csDisclosure(tab: String, probes: [String], breakMode: Bool) async {
        let header = "settings.disclosure.advanced." + tab
        _ = await click("settings.rail." + tab)
        _ = await waitUntil(timeout: 4) { UITestAnchors.frames[header] != nil }
        await settle(250)
        await csScrollToEnd(window)
        let closedAtStart = csAllAbsent(probes)
        let headerFrame = UITestAnchors.frames[header]
        _ = await click(header)
        let opened = await waitUntil(timeout: 3) { csAllPresent(probes) }
        _ = await click(header)
        let closedAgain = await waitUntil(timeout: 3) { csAllAbsent(probes) }
        // Break: expect the preferences to be visible before anyone pressed Advanced.
        let wantClosedAtStart = !breakMode
        record("\(tab): Advanced starts closed, a press shows its preferences, a second press hides them",
               closedAtStart == wantClosedAtStart && opened && closedAgain,
               "closedAtStart=\(closedAtStart) opened=\(opened) closedAgain=\(closedAgain) probes=\(probes)")
        record("\(tab): the Advanced header is at least 24 pt high and as wide as the pane content",
               (headerFrame?.height ?? 0) >= Metrics.minHit && (headerFrame?.width ?? 0) > 400,
               "header=\(headerFrame.map { "\(Int($0.width))x\(Int($0.height))" } ?? "nil")")
    }

    // MARK: 3. AI tab

    private static func csAIEgressAndProviders(breakMode: Bool) async {
        _ = await click("settings.rail.general")
        await settle(300)
        let onGeneral = UITestAnchors.frames["settings.ai.egress"] != nil
        _ = await click("settings.rail.ai")
        let shown = await waitUntil(timeout: 4) { UITestAnchors.frames["settings.ai.egress"] != nil }
        let frame = UITestAnchors.frames["settings.ai.egress"]
        // Break: look for the sentence on the General tab, where it is not.
        record("the AI tab shows the sentence that lists what is sent to the model, and General does not",
               breakMode ? onGeneral : (shown && !onGeneral && (frame?.width ?? 0) > 200 && (frame?.height ?? 0) > 10),
               "onGeneral=\(onGeneral) onAI=\(shown) frame=\(frame.map { "\(Int($0.width))x\(Int($0.height))" } ?? "nil")")

        #if KRONOS_PUBLIC
        var expected = ["openRouter"]
        #else
        var expected = ["ghostCLI", "openRouter"]
        #endif
        if breakMode { expected.append("custom") }
        let listed = AIProvider.presets.map(\.rawValue)
        record("the provider picker names the presets of this build and leaves the own-gateway provider to Other",
               listed == expected && !AIProvider.presets.contains(.custom), "listed=\(listed)")
    }

    // MARK: 4. MCP manual setup

    private static func csManualSetup(breakMode: Bool) async {
        let header = "settings.disclosure.manual.mcp"
        let snippet = "settings.mcp.copy.claudeCode"
        _ = await click("settings.rail.mcp")
        _ = await waitUntil(timeout: 4) { UITestAnchors.frames[header] != nil }
        await settle(250)
        let connectVisible = UITestAnchors.frames["settings.mcp.connectall"] != nil
        let closedAtStart = UITestAnchors.frames[snippet] == nil
        _ = await click(header)
        let opened = await waitUntil(timeout: 3) { UITestAnchors.frames[snippet] != nil }
        _ = await click(header)
        let closedAgain = await waitUntil(timeout: 3) { UITestAnchors.frames[snippet] == nil }
        // Break: expect the snippets to be on screen before Manual setup was pressed.
        record("MCP: Connect all is visible, the snippets start hidden under Manual setup, a press shows them and a second hides them",
               connectVisible && closedAtStart != breakMode && opened && closedAgain,
               "connect=\(connectVisible) closedAtStart=\(closedAtStart) opened=\(opened) closedAgain=\(closedAgain)")
    }

    // MARK: 5. empty House rules

    private static func csEmptyRules(_ model: AppModel, breakMode: Bool) async {
        guard model.store.allRules(includeInactive: true).isEmpty else {
            record("Planning: an empty House rules list shows its purpose line (store holds rules, step not applicable)", true, "rules present")
            return
        }
        _ = await click("settings.rail.planning")
        let shown = await waitUntil(timeout: 4) { UITestAnchors.frames["houserules.empty"] != nil }
        let frame = UITestAnchors.frames["houserules.empty"]
        // Break: expect the line to be missing.
        record("Planning: an empty House rules list shows one purpose line, tall enough to read",
               shown != breakMode && (frame?.height ?? 0) >= Metrics.controlRegular && (frame?.width ?? 0) > 300,
               "frame=\(frame.map { "\(Int($0.width))x\(Int($0.height))" } ?? "nil")")
    }

    // MARK: 6. last pane

    private static func csLastPane(breakMode: Bool) async {
        KronosEnv.defaults.removeObject(forKey: csLastTabKey)
        let fresh = SettingsTab.lastOpened == .general
        _ = await click("settings.rail.data")
        await settle(300)
        let afterData = SettingsTab.lastOpened == .data
        _ = await click("settings.rail.shortcuts")
        await settle(300)
        let afterShortcuts = SettingsTab.lastOpened == .shortcuts
        KronosEnv.defaults.set("coach", forKey: csLastTabKey)
        let staleFallsBack = SettingsTab.lastOpened == .general
        // Break: expect the pane after Data to be the one pressed before it.
        record("Settings reopens on the last pane (General when none or a retired one is stored)",
               fresh && afterData && afterShortcuts != breakMode && staleFallsBack,
               "fresh=\(fresh) afterData=\(afterData) afterShortcuts=\(afterShortcuts) stale=\(staleFallsBack)")
    }

    // MARK: 7. keyboard

    private static func csPost(_ chars: String, keyCode: UInt16) {
        key(chars, keyCode: keyCode)
    }

    private static func csKeyboard(breakMode: Bool) async {
        let probe = "settings.kbd.probe"
        let host = NSHostingController(rootView:
            SettingsAdvanced(tab: "kbd") { Text(verbatim: "probe").uiTestAnchor(probe) }
                .padding(Space.x6).frame(width: 520, height: 260, alignment: .topLeading).background(Tok.bg))
        let win = csWindow(host, width: 520, height: 260)
        let main = window
        window = win
        defer { window = main; win.orderOut(nil) }
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        _ = await waitUntil(timeout: 4) { UITestAnchors.frames["settings.disclosure.advanced.kbd"] != nil }
        await settle(300)
        win.makeFirstResponder(nil)

        // Tab onto the header (no click), then Space opens and Return closes.
        var reachedByTab = false
        if !breakMode {
            for _ in 0..<4 {
                csPost("\t", keyCode: 48)
                await settle(200)
                csPost(" ", keyCode: 49)
                await settle(300)
                if UITestAnchors.frames[probe] != nil { reachedByTab = true; break }
            }
        }
        var opened = UITestAnchors.frames[probe] != nil
        var viaClickFocus = false
        if !opened && !breakMode {
            // Full Keyboard Access off: Tab skips a button, so give it focus with one click on the
            // header and judge the keys themselves.
            _ = await click("settings.disclosure.advanced.kbd")
            await settle(300)
            csPost(" ", keyCode: 49)
            await settle(300)
            if UITestAnchors.frames[probe] == nil {
                // The click opened it and Space closed it: press Space once more to open.
                csPost(" ", keyCode: 49)
                await settle(300)
            }
            viaClickFocus = true
            opened = UITestAnchors.frames[probe] != nil
        }
        csPost("\r", keyCode: 36)
        let closed = await waitUntil(timeout: 2) { UITestAnchors.frames[probe] == nil }
        csPost(" ", keyCode: 49)
        let reopened = await waitUntil(timeout: 2) { UITestAnchors.frames[probe] != nil }
        record("the Advanced header works from the keyboard: Space opens it, Return closes it, Space opens it again",
               opened && closed && reopened,
               "reachedByTab=\(reachedByTab) focusedByClick=\(viaClickFocus) opened=\(opened) closed=\(closed) reopened=\(reopened)")
    }
}
#endif
