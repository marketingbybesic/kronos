// Live steps for the accessibility pass: Increase Contrast colours, the 24 pt view-options target at
// compact density and text size L, the tour (announcement per step, its primary button focused so Space
// acts), keyboard-only paths (the Avoiding it chip, a house rule's switch and Delete, P on the sort card)
// and the dread lock written by the chip. Run alone with `--only group:E-A11Y`.
// Keyboard paths run through a lone hosted control in a keyable window, so no neighbouring control can take
// the key; Full Keyboard Access is switched on for those steps when it is off (the guests have it on
// already) and put back right after, so the host lane and the guests drive the same Tab paths.
#if !RELEASE
import AppKit
import SwiftUI
import KronosCore

/// A borderless window that can take key focus, so presses reach the hosted controls.
private final class EA11yKeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

@MainActor
extension LiveUITest {

    static func eA11ySteps(_ model: AppModel) async {
        let breakMode = ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil
        await setWindowSize(width: 1500, height: 900)
        await runStep(model, scope: .all) { await ea11yIncreaseContrast($0, breakMode: breakMode) }
        await runStep(model, scope: .today) { await ea11yHitTargets($0, breakMode: breakMode) }
        await runStep(model, scope: .all) { await ea11yTour($0, breakMode: breakMode) }
        let restoreFKA = await ea11yEnableFullKeyboardAccess()
        await runStep(model, scope: .all) { await ea11yDreadChip($0, breakMode: breakMode) }
        await runStep(model, scope: .all) { await ea11yHouseRule($0, breakMode: breakMode) }
        restoreFKA()
        await runStep(model, scope: .all) { await ea11yTriageProjectPicker($0, breakMode: breakMode) }
        await resetState(model)
    }

    // MARK: Increase Contrast

    /// The tones behind the text tiers (KTone) resolve per appearance. Hand-written: tertiary is 0.52 and
    /// disabled 0.30 normally; both become the secondary tone, 0.66, under Increase Contrast. The values are tied
    /// to the shipped tokens by verify-contrast.mjs, which reads the same numbers out of Tokens.swift.
    private static func ea11yIncreaseContrast(_ model: AppModel, breakMode: Bool) async {
        func alpha(_ tone: NSColor, _ appearance: NSAppearance) -> Double {
            var a = -1.0
            appearance.performAsCurrentDrawingAppearance { a = Double(tone.usingColorSpace(.sRGB)?.alphaComponent ?? -1) }
            return a
        }
        func near(_ value: Double, _ want: Double) -> Bool { abs(value - want) < 0.005 }
        // An appearance made by name never carries the setting (it comes back plain); the tones ask KContrast, which
        // reads the system setting or this switch the design tools use, so the switch stands in for the setting.
        guard let plain = NSAppearance(named: .darkAqua) else { record("the dark appearance exists", false, "none"); return }
        let key = "KRONOS_SNAPSHOT_CONTRAST"
        let previous = ProcessInfo.processInfo.environment[key]
        defer { if let previous { setenv(key, previous, 1) } else { unsetenv(key) } }
        let tertiary = KTone.nsWhite(0.52, increasedContrast: 0.66), disabled = KTone.nsWhite(0.30, increasedContrast: 0.66)
        setenv(key, "increased", 1)
        let tertiaryIC = alpha(tertiary, plain), disabledIC = alpha(disabled, plain)
        unsetenv(key)
        let wantDisabled = breakMode ? 0.30 : 0.66
        record("under Increase Contrast tertiary and disabled text resolve to the secondary tone (0.66)",
               near(tertiaryIC, 0.66) && near(disabledIC, wantDisabled), "tertiary=\(tertiaryIC) disabled=\(disabledIC)")
        // Control: without the setting the tiers keep their own values (skipped when the system setting is on here).
        if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast || KContrast.forced {
            diagnostics.append("ea11y: Increase Contrast is on in this session, the plain-appearance control is skipped")
        } else {
            let t = alpha(tertiary, plain), d = alpha(disabled, plain)
            record("without Increase Contrast tertiary stays 0.52 and disabled 0.30 (the mapping is not always on)",
                   near(t, 0.52) && near(d, 0.30), "tertiary=\(t) disabled=\(d)")
        }
    }

    // MARK: Hit targets

    /// At compact density and text size L (the smallest the controls get) the view-options button and a list row
    /// keep a 24 x 24 pt area.
    private static func ea11yHitTargets(_ model: AppModel, breakMode: Bool) async {
        let oldDensity = DSScale.density, oldText = DSScale.text
        defer { DSScale.density = oldDensity; DSScale.text = oldText; model.didMutate() }
        DSScale.density = 0.86
        DSScale.text = 1.1
        let store = model.store
        let probe = store.createNoUndo(title: "A11y hit probe", notes: "", project: nil, status: .todo, priority: .none, dueDay: Day.today())
        defer { store.softDeleteNoUndo(probe.id); model.didMutate() }
        model.didMutate()
        _ = await waitUntil(timeout: 4) { UITestAnchors.frames["viewoptions.button"] != nil && UITestAnchors.frames["row.A11y hit probe"] != nil }
        await waitStable { UITestAnchors.frames["viewoptions.button"] ?? .zero }
        let button = UITestAnchors.frames["viewoptions.button"] ?? .zero
        let row = UITestAnchors.frames["row.A11y hit probe"] ?? .zero
        let floor = breakMode ? 200 : Metrics.minHit
        record("the view-options button is at least 24 x 24 pt at compact density and text size L",
               button.width >= floor && button.height >= floor, "button=\(Int(button.width))x\(Int(button.height))")
        record("a list row is at least 24 pt tall at compact density and text size L",
               row.height >= floor, "row height=\(Int(row.height))")
    }

    // MARK: Tour

    /// Each step is announced (the text is kept for the test), and the bubble's primary button has the keyboard:
    /// Space moves to the next step with nothing clicked.
    private static func ea11yTour(_ model: AppModel, breakMode: Bool) async {
        let center = TourCenter.shared
        defer { if center.isRunning { center.end() }; model.didMutate() }
        func title(_ step: TourStep) -> String { String(localized: String.LocalizationValue(step.titleKey)) }
        _ = await ensureKey()
        center.start(model: model, sample: true)
        let shown = await waitUntil(timeout: 6) { UITestAnchors.frames["tour.next"] != nil }
        guard shown, let first = center.step, let firstIndex = center.index else {
            record("the tour bubble appears", false, "shown=\(shown)"); return
        }
        _ = await waitUntil(timeout: 3) { TourAnnouncer.last.contains(title(first)) }
        record("the tour announces its first step with position, title and text",
               TourAnnouncer.last.contains(title(first)) && TourAnnouncer.last.contains(String(localized: String.LocalizationValue(first.bodyKey))),
               "announced=\(TourAnnouncer.last.prefix(120))")

        // The primary button has the keyboard: Space presses it.
        await settle(400)
        key(" ", keyCode: 49)
        let advanced = await waitUntil(timeout: 3) { (center.index ?? firstIndex) != firstIndex }
        record("with the bubble focused, Space alone moves the tour to the next step",
               breakMode ? !advanced : advanced, "index \(firstIndex) -> \(String(describing: center.index))")

        // Every further step is announced as it appears.
        var announced = 0, steps = 0
        var missing: [String] = []
        for _ in 0..<12 {
            guard let step = center.step else { break }
            steps += 1
            if await waitUntil(timeout: 3, { TourAnnouncer.last.contains(title(step)) }) { announced += 1 } else { missing.append(step.titleKey) }
            center.next()
            await settle(450)
        }
        record("every later tour step is announced with its title", steps >= 2 && announced == steps && missing.isEmpty,
               "steps=\(steps) announced=\(announced) missing=\(missing)")
        if center.isRunning { center.end() }
    }

    // MARK: Keyboard paths

    private static func ea11yHost<V: View>(_ view: V, width: CGFloat = 520, height: CGFloat = 220) -> NSWindow {
        let host = NSHostingController(rootView: view.padding(Space.x4).frame(width: width, height: height, alignment: .topLeading).background(Tok.bg))
        let w = EA11yKeyableWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentViewController = host
        w.setContentSize(NSSize(width: width, height: height))
        w.center()
        return w
    }

    /// Where the previous value of Full Keyboard Access is parked while a run has it switched on: a run that dies
    /// before it puts the setting back leaves this file, and the next run restores from it first.
    private static var fkaSentinel: URL { URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kronos-uitest-fka-restore.txt") }

    private static func fkaDefaults(_ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        p.waitUntilExit()
        return (p.terminationStatus, String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }

    /// A running process reads the setting once; the system posts this notification when it changes, and AppKit
    /// re-reads it on receipt (a fresh process needs nothing). Measured: without it the value stayed false for 3 s.
    private static func fkaAnnounce() {
        DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.apple.KeyboardUIModeDidChange"), object: nil, userInfo: nil, deliverImmediately: true)
    }

    private static func fkaRestore(from saved: String) {
        if saved == "unset" { _ = fkaDefaults(["delete", "-g", "AppleKeyboardUIMode"]) }
        else if let mode = Int(saved) { _ = fkaDefaults(["write", "-g", "AppleKeyboardUIMode", "-int", String(mode)]) }
        fkaAnnounce()
        try? FileManager.default.removeItem(at: fkaSentinel)
    }

    /// Makes the keyboard paths run the way they do in the guests, where Full Keyboard Access is on: Tab then
    /// reaches buttons and switches. The setting (AppleKeyboardUIMode) is read from the system, not per process, so it
    /// cannot be scoped to this process; instead it is switched on for the keyboard steps only, the previous value is
    /// parked in a file first, and the returned closure puts it back (a crashed run is undone by the next one). When
    /// the setting is already on nothing is touched.
    private static func ea11yEnableFullKeyboardAccess() async -> () -> Void {
        var vm: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let inVM = sysctlbyname("kern.hv_vmm_present", &vm, &size, nil, 0) == 0 && vm == 1
        if let stale = try? String(contentsOf: fkaSentinel, encoding: .utf8) {
            fkaRestore(from: stale.trimmingCharacters(in: .whitespacesAndNewlines))
            diagnostics.append("ea11y: restored Full Keyboard Access left by an earlier run")
        }
        diagnostics.append("ea11y: virtual machine=\(inVM) fullKeyboardAccess=\(NSApp.isFullKeyboardAccessEnabled)")
        if NSApp.isFullKeyboardAccessEnabled { return {} }
        let before = fkaDefaults(["read", "-g", "AppleKeyboardUIMode"])
        let saved = before.0 == 0 ? before.1 : "unset"
        try? saved.write(to: fkaSentinel, atomically: true, encoding: .utf8)
        _ = fkaDefaults(["write", "-g", "AppleKeyboardUIMode", "-int", "3"])
        fkaAnnounce()
        let on = await waitUntil(timeout: 3) { NSApp.isFullKeyboardAccessEnabled }
        diagnostics.append("ea11y: Full Keyboard Access switched on for the keyboard steps=\(on) (was \(saved))")
        return { fkaRestore(from: saved) }
    }

    /// Tab reaches the Avoiding it chip, Space switches it off, and that decision is locked against triage.
    private static func ea11yDreadChip(_ model: AppModel, breakMode: Bool) async {
        let store = model.store
        let mainWindow: NSWindow = window
        let task = store.createNoUndo(title: "A11y dread probe", notes: "", project: nil, status: .todo, priority: .none, dueDay: Day.today())
        store.updateNoUndo(task.id) { $0.dread = true }
        model.didMutate()
        let win = ea11yHost(InspectorDreadToggle(model: model, task: task), height: 120)
        window = win
        defer {
            win.orderOut(nil)
            window = mainWindow
            mainWindow.makeKeyAndOrderFront(nil)
            store.softDeleteNoUndo(task.id)
            model.didMutate()
        }
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        _ = await waitUntil(timeout: 4) { UITestAnchors.frames["inspector.dread"] != nil }
        await settle(300)
        win.makeFirstResponder(nil)
        key("\t", keyCode: 48)
        await settle(300)
        key(" ", keyCode: 49)
        let off = await waitUntil(timeout: 3) { store.task(task.id)?.dread == false }
        let after = store.task(task.id)
        record("from the keyboard alone (Tab, Space) the Avoiding it chip switches the flag off",
               breakMode ? !off : off, "dread=\(String(describing: after?.dread)) fullKeyboardAccess=\(NSApp.isFullKeyboardAccessEnabled)")
        record("switching Avoiding it off by hand locks it against triage",
               breakMode ? after?.dreadLocked != true : after?.dreadLocked == true,
               "locked=\(String(describing: after?.dreadLocked)) raw=\(after?.lockedFieldsRaw ?? "nil")")
    }

    /// Tab reaches a house rule's switch, Space flips it; Tab reaches Delete, Space asks, Space deletes.
    private static func ea11yHouseRule(_ model: AppModel, breakMode: Bool) async {
        let store = model.store
        let mainWindow: NSWindow = window
        let rule = store.addRule(text: "Keep every first move under sixty characters.", scope: .all, source: .manual)
        model.didMutate()
        let win = ea11yHost(SettingsHouseRulesSection(model: model), width: 700, height: 360)
        window = win
        defer {
            win.orderOut(nil)
            window = mainWindow
            mainWindow.makeKeyAndOrderFront(nil)
            _ = store.deleteRule(rule.id)
            model.didMutate()
        }
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        _ = await waitUntil(timeout: 4) { UITestAnchors.frames["houserules.toggle.0"] != nil }
        await settle(300)
        func current() -> KRule? { store.allRules(includeInactive: true).first { $0.id == rule.id } }
        let startedActive = current()?.isActive == true
        win.makeFirstResponder(nil)
        key("\t", keyCode: 48); await settle(300)
        key(" ", keyCode: 49)
        let switched = await waitUntil(timeout: 3) { current()?.isActive == false }
        record("from the keyboard alone (Tab, Space) a house rule's switch turns it off",
               startedActive && (breakMode ? !switched : switched), "started=\(startedActive) active=\(String(describing: current()?.isActive)) fullKeyboardAccess=\(NSApp.isFullKeyboardAccessEnabled)")
        key("\t", keyCode: 48); await settle(300)
        key(" ", keyCode: 49); await settle(400)
        let stillThere = current() != nil
        key(" ", keyCode: 49)
        let deleted = await waitUntil(timeout: 3) { current() == nil }
        record("from the keyboard alone Delete asks first (Space) and deletes on the second Space",
               stillThere && (breakMode ? !deleted : deleted), "afterFirstSpace=\(stillThere) deleted=\(deleted)")
    }

    // MARK: Sort card P

    /// P on the sort card opens the same type-ahead picker as the list; Return files the task and the card stays;
    /// Esc closes only the picker.
    private static func ea11yTriageProjectPicker(_ model: AppModel, breakMode: Bool) async {
        let store = model.store
        let main: NSWindow = window
        let project = store.createProject(name: "Zebra picker probe", colorHex: "#8224E3", icon: nil, area: nil)
        let task = store.create(title: "A11y picker probe")
        store.updateNoUndo(task.id) { $0.createdAt = Date(timeIntervalSince1970: 1_000_000) }
        model.didMutate()
        defer {
            if model.isTriageOpen { model.isTriageOpen = false }
            window = main
            store.softDeleteNoUndo(task.id)
            model.didMutate()
        }
        _ = await ensureKey()
        TriageLaunch.shared.request(.sort)
        model.isTriageOpen = true
        let shown = await waitUntil(timeout: 5) { UITestAnchors.frames["triage.card.progress"] != nil }
        await settle(400)
        let first = TriageQueue.ordered(in: store.allTasks()).first?.id
        record("the sort card opens on the probe task", shown && first == task.id, "shown=\(shown) first=\(String(describing: first)) want=\(task.id)")

        // The picker is a popover. Its window does not become the key window (typing, Return and Esc reach it through
        // the picker's own key monitor while the main window stays key), so open and closed are read from the
        // popover window itself. (Its anchor frame is not used: it can outlive the popover.)
        func popoverUp() -> Bool {
            NSApp.windows.contains { $0 !== main && $0.isVisible && ($0.className.contains("Popover") || $0.parent === main) }
        }
        key("p", keyCode: 35)
        let opened = await waitUntil(timeout: 3) { popoverUp() }
        record("P opens the project picker on the card", opened, "popover window shown=\(opened) anchor=\(UITestAnchors.frames["triage.project.picker"] != nil)")
        await typeText("zebra")
        await settle(250)
        key("\r", keyCode: 36)
        let filed = await waitUntil(timeout: 3) { store.task(task.id)?.projectID == project.id }
        let closedAfterPick = await waitUntil(timeout: 3) { !popoverUp() }
        await settle(300)
        record("typing part of a project name and Return files the task there",
               breakMode ? !filed : filed, "project=\(store.task(task.id)?.project?.name ?? "nil")")
        record("the picker closes and the card stays open on its task (Return did not also accept the card)",
               opened && closedAfterPick && model.isTriageOpen && TriageQueue.ordered(in: store.allTasks()).first?.id == task.id,
               "pickerClosed=\(closedAfterPick) open=\(model.isTriageOpen)")

        key("p", keyCode: 35)
        let reopened = await waitUntil(timeout: 3) { popoverUp() }
        key("\u{1B}", keyCode: 53)
        let closed = await waitUntil(timeout: 3) { !popoverUp() }
        record("Esc in the picker closes only the picker, not the card", reopened && closed && model.isTriageOpen,
               "reopened=\(reopened) pickerClosed=\(closed) cardOpen=\(model.isTriageOpen)")
    }
}
#endif
