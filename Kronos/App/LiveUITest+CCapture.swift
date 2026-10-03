// Kronos/App/LiveUITest+CCapture.swift
// Live steps for quick add (⌃⌥K) and capture. Run alone with `--only group:C-CAPTURE`.
//   - Return chords: ⏎ adds and closes, ⌘⏎ adds and stays (field empty), ⌥⏎ adds and keeps
//     the pills, ⏎ on an empty field closes, ⌘⏎/⌥⏎ on an empty field do nothing; the inline
//     list row keeps "Return adds and clears" for every chord.
//   - one acknowledgement: the undo pill names where the task went.
//   - the legend opens by itself for the first three adds, not after.
//   - context: opened over a (scripted) Safari the page title is the starting title and the
//     page a web chip that lands on the task; a (scripted) Mail that does not hand over the
//     message link in time leaves the subject alone within 2 s; the consent chip asks and reads.
//   - "every week" makes a repeating task; the inline add row grows with its lines.
//   - Capture: a task made from a reminder keeps its origin when its title was edited in review.
// The system side of context is a scripted environment (no Apple Events, no Accessibility):
// the real reader, panel, chips and create path run; only osascript is replaced.
// Plus the older quick add steps this area owns (panel typing, entry field, other surfaces),
// so one leaf run covers every quick add step.
#if !RELEASE
import AppKit
import KronosCore

/// Canned Automation answers and script outputs for the live run.
final class LiveScriptedContext: QuickAddContextEnvironment, @unchecked Sendable {
    var answers: [String: QuickAddAutomation] = [:]
    /// (word the script contains, output, seconds before it answers)
    var outputs: [(String, String, Double)] = []
    private(set) var askedCount = 0

    func automation(_ bundleID: String, ask: Bool) async -> QuickAddAutomation {
        let answer = answers[bundleID] ?? .denied
        if ask, answer == .notAsked {
            await MainActor.run { askedCount += 1 }
            return .granted
        }
        return answer
    }

    func runScript(_ source: String, timeout: TimeInterval) async -> String? {
        guard let hit = outputs.first(where: { source.contains($0.0) }) else { return nil }
        // Same contract as the live runner: no answer within the timeout is nil, in time.
        try? await Task.sleep(for: .seconds(min(hit.2, timeout)))
        return hit.2 > timeout ? nil : hit.1
    }

    func selectedText(pid: Int32) async -> String? { nil }
}

@MainActor
extension LiveUITest {

    private static func ccSettle(_ ms: Int = 400) async { try? await Task.sleep(for: .milliseconds(ms)) }

    private static func ccType(_ text: String) async {
        for ch in text { key(String(ch)); try? await Task.sleep(for: .milliseconds(25)) }
        await ccSettle(250)
    }

    private static func ccPanel(_ main: NSWindow) -> NSPanel? {
        NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible && $0 !== main && $0.canBecomeKey }) as? NSPanel
    }

    /// Opens the panel the way the hotkey does and points the key helpers at it.
    private static func ccOpen(_ main: NSWindow) async -> (NSPanel, EntryFieldModel)? {
        // No restored draft from the step before: every step starts from an empty field.
        QuickAddDraft.text = ""
        AppDelegate.shared?.quickAdd.toggle()
        await waitUntil(timeout: 4) { ccPanel(main) != nil }
        guard let panel = ccPanel(main), let entry = AppDelegate.shared?.quickAdd.entry else { return nil }
        for _ in 0..<20 where !(NSApp.isActive && panel.isKeyWindow) {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            await ccSettle(100)
        }
        await waitUntil(timeout: 3) { NSApp.keyWindow?.firstResponder is NSTextView }
        // The caret must be in the panel's own field: the first key typed into a panel whose field is
        // not yet first responder is lost (a full run lost the leading "c").
        await waitUntil(timeout: 3) { entry.textView.map { panel.firstResponder === $0 } ?? false }
        await ccSettle(200)
        window = panel
        return (panel, entry)
    }

    private static func ccClose(_ panel: NSPanel, _ main: NSWindow) async {
        if panel.isVisible { AppDelegate.shared?.quickAdd.toggle(); await waitUntil(timeout: 2) { !panel.isVisible } }
        window = main
        await ensureKey(main)
    }

    private static func ccTask(_ title: String) -> KTask? {
        AppDelegate.shared?.store.allTasks().first { $0.title == title }
    }

    static func cCaptureSteps(_ model: AppModel) async {
        let main = window!
        let breakMode = ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil
        let controller = AppDelegate.shared!.quickAdd
        let defaults = KronosEnv.defaults
        defaults.set(0, forKey: QuickAddController.addsCountKey)
        defaults.set(false, forKey: QuickAddPanelView.legendOpenKey)
        model.scope = .inbox
        await ensureKey(main)

        await ccReturnChords(model, main: main, breakMode: breakMode)
        await ccContext(model, main: main, controller: controller)
        await ccRepeatAndInline(model, main: main)
        await ccReminderOrigin(model)

        controller.contextEnvironment = NullQuickAddContextEnvironment()
        controller.frontAppOverride = nil
        for t in model.store.allTasks() where t.title.hasPrefix("ccap ") { model.store.softDeleteNoUndo(t.id) }
        model.didMutate()
        window = main
        await ensureKey(main)

        // The older quick add steps, with the Return chords they now have.
        await quickAddPanelTypes(model)
        await entryFieldPanelSteps(model)
        await entrySurfaceSteps(model)
    }

    // MARK: Return chords, acknowledgement, legend

    private static func ccReturnChords(_ model: AppModel, main: NSWindow, breakMode: Bool) async {
        let store = model.store
        guard let (p1, e1) = await ccOpen(main) else { record("quick add: panel opens", false, "no panel"); return }
        record("quick add: the legend opens by itself on a first add",
               UITestAnchors.frames["quickadd.legend"] != nil, "legend=\(UITestAnchors.frames["quickadd.legend"] != nil)")
        _ = e1
        await ccType("ccap close one")
        key("\r", keyCode: 36)
        let closed = await waitUntil(timeout: 2) { !p1.isVisible }
        await waitUntil(timeout: 2) { ccTask("ccap close one") != nil }
        let made = ccTask("ccap close one")
        let ack = UndoToastCenter.shared.current?.message ?? ""
        let wantAck = String(format: String(localized: "quickadd.ack.to"), String(localized: "sidebar.inbox"))
        record("quick add: Return adds the task and closes the panel",
               made != nil && (breakMode ? !closed : closed), "task=\(made != nil) closed=\(closed)")
        record("quick add: one acknowledgement says where the task went",
               ack.hasPrefix(wantAck), "pill=\(ack.debugDescription) want=\(wantAck.debugDescription)")
        window = main
        await ensureKey(main)

        guard let (p2, e2) = await ccOpen(main) else { record("quick add: panel reopens", false, "no panel"); return }
        await ccType("ccap stay one !!")
        let pillBefore = e2.resolved.priority == .medium
        key("\r", modifiers: .command, keyCode: 36)
        await waitUntil(timeout: 2) { ccTask("ccap stay one") != nil }
        await ccSettle(300)
        record("quick add: Command-Return adds, stays open and empties the field",
               ccTask("ccap stay one")?.priority == .medium && p2.isVisible && e2.text.isEmpty && e2.pills.isEmpty && pillBefore,
               "task=\(ccTask("ccap stay one") != nil) visible=\(p2.isVisible) text=\(e2.text.debugDescription) pills=\(e2.pills)")

        await ccType("ccap keep one !!!")
        key("\r", modifiers: .option, keyCode: 36)
        await waitUntil(timeout: 2) { ccTask("ccap keep one") != nil }
        await ccSettle(300)
        let kept = e2.pills.contains(.priority(.high))
        await ccType("ccap keep two")
        key("\r", keyCode: 36)
        await waitUntil(timeout: 2) { !p2.isVisible }
        record("quick add: Option-Return adds, stays open and keeps the pills for the next one",
               kept && ccTask("ccap keep two")?.priority == .high && !p2.isVisible,
               "kept=\(kept) two=\(String(describing: ccTask("ccap keep two")?.priority)) visible=\(p2.isVisible)")
        window = main
        await ensureKey(main)

        // Four adds so far: the legend no longer opens by itself.
        guard let (p3, _) = await ccOpen(main) else { record("quick add: panel reopens", false, "no panel"); return }
        record("quick add: after three adds the legend stays closed",
               UITestAnchors.frames["quickadd.legend"] == nil, "legend=\(UITestAnchors.frames["quickadd.legend"] != nil)")
        let before = store.allTasks().count
        key("\r", modifiers: .command, keyCode: 36); await ccSettle(300)
        key("\r", modifiers: .option, keyCode: 36); await ccSettle(300)
        let stillOpen = p3.isVisible
        key("\r", keyCode: 36)
        let emptyClosed = await waitUntil(timeout: 2) { !p3.isVisible }
        record("quick add: on an empty field Command-/Option-Return do nothing and Return closes",
               stillOpen && emptyClosed && store.allTasks().count == before,
               "openAfterChords=\(stillOpen) closed=\(emptyClosed) tasks \(before)->\(store.allTasks().count)")
        window = main
        await ensureKey(main)

        // Another surface: the inline add row of a list keeps "Return adds and clears".
        model.scope = .inbox
        await ensureKey(main)
        await ccSettle(500)
        _ = await click("inlineadd.field", xFraction: 0.3)
        await ccSettle(300)
        await ccType("ccap inline one")
        key("\r", modifiers: .command, keyCode: 36)
        await waitUntil(timeout: 2) { ccTask("ccap inline one") != nil }
        await ccSettle(300)
        record("inline row: Command-Return adds and clears like Return (no panel)",
               ccTask("ccap inline one") != nil && ccPanel(main) == nil,
               "task=\(ccTask("ccap inline one") != nil) panel=\(ccPanel(main) != nil)")
    }

    // MARK: Context

    private static func ccContext(_ model: AppModel, main: NSWindow, controller: QuickAddController) async {
        let safari = QuickAddFrontApp(bundleID: "com.apple.Safari", pid: 1, name: "Safari")
        let env = LiveScriptedContext()
        env.answers["com.apple.Safari"] = .granted
        env.outputs = [("current tab", "ccap Quarterly report\thttps://example.com/reports/q3", 0.1)]
        controller.contextEnvironment = env
        controller.frontAppOverride = safari

        guard let (p1, e1) = await ccOpen(main) else { record("context: panel opens", false, "no panel"); return }
        let chip = await waitUntil(timeout: 3) { UITestAnchors.frames["quickadd.context.web"] != nil }
        let x = UITestAnchors.frames["quickadd.context.web.remove"] ?? .zero
        record("context: over Safari the page title is the starting title and the page a web chip",
               chip && e1.text == "ccap Quarterly report",
               "chip=\(chip) text=\(e1.text.debugDescription)")
        record("context: the chip's remove control is at least 24 x 24 pt",
               x.width >= Metrics.minHit && x.height >= Metrics.minHit, "x=\(Int(x.width))x\(Int(x.height))")
        key("\r", keyCode: 36)
        await waitUntil(timeout: 2) { !p1.isVisible }
        let linked = ccTask("ccap Quarterly report").map { ContextLink.findAll(in: $0.notes) } ?? []
        record("context: Return files the task with the page linked",
               linked.map(\.reference) == ["https://example.com/reports/q3"] && linked.first?.kind == .web,
               "links=\(linked.map(\.encodedLine))")
        window = main
        await ensureKey(main)

        // Mail hands over the subject at once but never the message link: subject only, in time.
        let mail = LiveScriptedContext()
        mail.answers["com.apple.mail"] = .granted
        mail.outputs = [("subject of", "ccap Invoice 2291", 0), ("message id of", "<id@example.com>", 5)]
        controller.contextEnvironment = mail
        controller.frontAppOverride = QuickAddFrontApp(bundleID: "com.apple.mail", pid: 1, name: "Mail")
        let start = Date()
        guard let (p2, e2) = await ccOpen(main) else { record("context: panel opens over Mail", false, "no panel"); return }
        let gotSubject = await waitUntil(timeout: 3) { e2.text == "ccap Invoice 2291" }
        let elapsed = Date().timeIntervalSince(start)
        await ccSettle(1200)
        record("context: Mail with no answer in 1 s falls back to the subject",
               gotSubject && elapsed < 2.5 && UITestAnchors.frames["quickadd.context.email"] == nil
                   && (controller.context?.links.isEmpty ?? false),
               "subject=\(gotSubject) after=\(String(format: "%.2f", elapsed))s chip=\(UITestAnchors.frames["quickadd.context.email"] != nil)")
        await ccClose(p2, main)

        // Not asked yet: a chip asks, and only then is the tab read.
        let ask = LiveScriptedContext()
        ask.answers["com.apple.Safari"] = .notAsked
        ask.outputs = [("current tab", "ccap Asked page\thttps://example.com/asked", 0)]
        controller.contextEnvironment = ask
        controller.frontAppOverride = safari
        guard let (p3, _) = await ccOpen(main) else { record("context: panel opens for consent", false, "no panel"); return }
        let consentShown = await waitUntil(timeout: 3) { UITestAnchors.frames["quickadd.context.consent"] != nil }
        let noChipYet = UITestAnchors.frames["quickadd.context.web"] == nil
        _ = await click("quickadd.context.consent", xFraction: 0.5)
        let readAfter = await waitUntil(timeout: 3) { UITestAnchors.frames["quickadd.context.web"] != nil }
        record("context: an unknown permission shows a chip that asks, and reads only after the click",
               consentShown && noChipYet && readAfter && ask.askedCount == 1 && p3.isVisible,
               "consent=\(consentShown) noChipYet=\(noChipYet) read=\(readAfter) asked=\(ask.askedCount) visible=\(p3.isVisible)")
        await ccClose(p3, main)
        controller.contextEnvironment = NullQuickAddContextEnvironment()
        controller.frontAppOverride = nil
    }

    // MARK: Repeat, inline row lines

    private static func ccRepeatAndInline(_ model: AppModel, main: NSWindow) async {
        guard let (p1, _) = await ccOpen(main) else { record("repeat: panel opens", false, "no panel"); return }
        await ccType("ccap repeat report every week")
        let pill = UITestAnchors.frames["entry.pill.repeat"] != nil
        key("\r", keyCode: 36)
        await waitUntil(timeout: 2) { !p1.isVisible }
        let t = ccTask("ccap repeat report")
        let rule = t?.recurrenceRule.flatMap(RecurrenceRule.parse)
        let today = Day.today(calendar: KronosLocale.calendar)
        var weeklyToday = false
        if case .weekly(1, _, .fromDueDay)? = rule { weeklyToday = t?.dueDay == today }
        record("repeat: \"every week\" shows a pill and makes a weekly task starting today",
               pill && weeklyToday, "pill=\(pill) rule=\(t?.recurrenceRule ?? "nil") due=\(String(describing: t?.dueDay)) today=\(today)")
        window = main
        await ensureKey(main)

        model.scope = .inbox
        await ccSettle(500)
        _ = await click("inlineadd.field", xFraction: 0.3)
        await ccSettle(300)
        let oneLine = UITestAnchors.frames["inlineadd.field"]?.height ?? 0
        await ccType("ccap lines")
        key("\r", modifiers: .shift, keyCode: 36); await ccSettle(150)
        await ccType("- second")
        key("\r", modifiers: .shift, keyCode: 36); await ccSettle(150)
        await ccType("- third")
        await ccSettle(300)
        let threeLines = UITestAnchors.frames["inlineadd.field"]?.height ?? 0
        record("inline row: the editor grows with each line",
               oneLine > 0 && threeLines >= oneLine * 2, "one=\(Int(oneLine)) three=\(Int(threeLines))")
        key("\r", keyCode: 36)
        await waitUntil(timeout: 2) { ccTask("ccap lines") != nil }
        record("inline row: the lines become a task with its subtasks",
               ccTask("ccap lines")?.orderedSubtasks.map(\.title) == ["second", "third"],
               "subtasks=\(ccTask("ccap lines")?.orderedSubtasks.map(\.title) ?? [])")
    }

    // MARK: Capture

    private static func ccReminderOrigin(_ model: AppModel) async {
        let item = ReminderItem(title: "ccap reminder", notes: nil, due: nil, listName: "Nowhere", id: "CC-ONE")
        let capture = CaptureModel(model: model)
        capture.remindersProvider = FixtureReminders(access: .granted, items: [item])
        let savedFlag = RemindersImport.markComplete
        RemindersImport.markComplete = false
        await capture.importFromReminders()
        if let row = capture.rows.first { capture.update(row.id) { $0.title = "ccap reminder renamed" } }
        capture.create()
        await ccSettle(300)
        let t = ccTask("ccap reminder renamed")
        record("capture: a task made from a reminder keeps its origin after its title was edited",
               t?.externalID == "reminders:CC-ONE" && t?.source == "reminders" && capture.createdReminders == [item],
               "ext=\(t?.externalID ?? "nil") source=\(t?.source ?? "nil") created=\(capture.createdReminders.map(\.id))")
        RemindersImport.markComplete = savedFlag
    }
}
#endif
