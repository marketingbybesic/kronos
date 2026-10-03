// Live steps for the block-start notification channel. Run alone with `--only group:D-NOTIFY`.
// Every step runs against the scratch store of the test run, a private defaults suite and the
// recording notification center: the real system center is never created, asked or used.
// `KRONOS_UITEST_BREAK=1` flips one expectation in each behaviour group: the run must then fail.
#if !RELEASE
import AppKit
import SwiftUI
import KronosCore

@MainActor
extension LiveUITest {
    static func dNotifySteps(_ model: AppModel) async {
        let breakMode = ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil
        guard KronosEnv.isHermetic else { record("notify[L1]: runs only on a scratch store", false, "not hermetic"); return }
        offByDefault()
        await permissionFlow(breakMode: breakMode)
        await hitTargets()
        await keyboardPath(breakMode: breakMode)
        await planTable(model, breakMode: breakMode)
        await actions(model, breakMode: breakMode)
    }

    // MARK: Fixtures

    private static let fixtureStart = Date(timeIntervalSince1970: 1_790_000_000)
    private static let anchors = ["settings.notify.toggle", "settings.notify.continue", "settings.notify.cancel", "settings.notify.opensettings"]

    private static func scratchNotifier(center: RecordingNotificationCenter, clock: FixtureClock? = nil,
                                        model: AppModel? = nil) -> BlockStartNotifications {
        let clock = clock ?? FixtureClock(now: fixtureStart)
        let suite = UserDefaults(suiteName: "kronos.dnotify.test.\(UUID().uuidString)") ?? .standard
        let notifier = BlockStartNotifications(defaults: suite, clock: clock, makeCenter: { center })
        if let model { notifier.attach(model: model) }
        return notifier
    }

    /// Hosts the real Settings section in its own window, runs `body`, and puts the test window back.
    private static func hosted(_ notifier: BlockStartNotifications, _ body: () async -> Void) async {
        for id in anchors { UITestAnchors.frames[id] = nil }
        let host = NSHostingView(rootView: SettingsNotificationsSection(notifier: notifier)
            .padding(Space.x4).frame(width: 640, height: 420, alignment: .top).background(Tok.bg))
        let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 640, height: 420), styleMask: [.titled],
                         backing: .buffered, defer: false)
        w.contentView = host
        w.makeKeyAndOrderFront(nil)
        await waitUntil(timeout: 3) { NSApp.isActive && w.isKeyWindow }
        await waitUntil(timeout: 3) { UITestAnchors.frames["settings.notify.toggle"] != nil }
        await waitStable { UITestAnchors.frames["settings.notify.toggle"] ?? .zero }
        let main = window
        window = w
        await body()
        window = main
        w.orderOut(nil)
    }

    private static func calendarEvent(_ id: String, _ title: String, from offset: TimeInterval) -> TimeBlockEntry {
        let start = fixtureStart.addingTimeInterval(offset)
        return TimeBlockEntry(event: KCalendarEvent(id: id, title: title, start: start, end: start.addingTimeInterval(3600),
                                                    isAllDay: false, calendarID: "fixture"), projectID: nil)
    }

    private static func linkedTask(_ model: AppModel, _ title: String, to entry: TimeBlockEntry, firstMove: String? = nil,
                                   dueDay: Int? = nil) -> KTask {
        let link = TaskCalendarLink(eventID: entry.event.id, title: entry.event.title, start: entry.event.start, end: entry.event.end)
        let task = model.store.createNoUndo(title: title, notes: link.appending(to: ""), dueDay: dueDay)
        if let firstMove { model.store.updateNoUndo(task.id) { $0.firstMove = firstMove } }
        return task
    }

    // MARK: L1

    private static func offByDefault() {
        let center = RecordingNotificationCenter()
        let fresh = scratchNotifier(center: center)
        let shared = BlockStartNotifications.shared
        let sharedUntouched = !shared.hasCenter
        let sharedOff = !shared.isEnabled
        let hermeticCenter = BlockStartNotifications.defaultCenter() is RecordingNotificationCenter
        record("notify[L1]: off by default, a test run builds the recording center, nothing was asked at launch",
               !fresh.isEnabled && fresh.stage == .idle && !fresh.hasCenter && center.requestCount == 0
                   && sharedOff && sharedUntouched && hermeticCenter,
               "freshEnabled=\(fresh.isEnabled) freshCenter=\(fresh.hasCenter) asked=\(center.requestCount) sharedOff=\(sharedOff) sharedUntouched=\(sharedUntouched) recording=\(hermeticCenter)")
    }

    /// Presses Continue (Return, the default button) or Not now (Escape) once the button has settled. A synthetic
    /// mouse click does not reach SwiftUI buttons in a hosted test window, so the keyboard route is the one proven here.
    private static func clickSettled(_ id: String, label: String) async {
        await waitUntil(timeout: 3) { UITestAnchors.frames[id] != nil }
        await waitStable { UITestAnchors.frames[id] ?? .zero }
        await settle(150)
        _ = await ensureKey(window)
        if id == "settings.notify.cancel" { key("\u{1B}", keyCode: 53) } else { key("\r", keyCode: 36) }
        lastPress = label.isEmpty ? "none" : "key"
    }

    private static var lastPress = "none"

    private static var lastFlip = "none"

    /// Presses the real switch control of the hosted section (a synthetic mouse click does not move a SwiftUI switch).
    private static func flipSwitch(_ notifier: BlockStartNotifications) async {
        func find(_ v: NSView) -> NSControl? {
            if let s = v as? NSSwitch { return s }
            for sub in v.subviews { if let hit = find(sub) { return hit } }
            return nil
        }
        if let control = window.contentView.flatMap(find) {
            control.performClick(nil)
            lastFlip = "switch"
        } else {
            await notifier.setEnabled(true)
            lastFlip = "direct"
        }
    }

    // MARK: L2 L3 L4

    private static func permissionFlow(breakMode: Bool) async {
        // L2: toggle -> explanation first, system asked once only after Continue.
        let center = RecordingNotificationCenter()
        let notifier = scratchNotifier(center: center)
        var askedBeforeContinue = -1
        var stageAfterToggle = BlockStartNotifications.Stage.idle
        await hosted(notifier) {
            await flipSwitch(notifier)
            await waitUntil(timeout: 3) { notifier.stage == .prePermission }
            stageAfterToggle = notifier.stage
            askedBeforeContinue = center.requestCount
            await clickSettled("settings.notify.continue", label: String(localized: "settings.notifications.pre.continue"))
            await waitUntil(timeout: 3) { notifier.isEnabled }
        }
        record("notify[L2]: toggle shows the explanation first; Continue asks the system exactly once and enables",
               stageAfterToggle == .prePermission && askedBeforeContinue == 0 && notifier.isEnabled
                   && center.requestCount == (breakMode ? 2 : 1) && notifier.stage == .idle,
               "flip=\(lastFlip) press=\(lastPress) stage=\(stageAfterToggle) askedBefore=\(askedBeforeContinue) asked=\(center.requestCount) enabled=\(notifier.isEnabled)")

        // L3: Cancel keeps it off and never asks.
        let cancelCenter = RecordingNotificationCenter()
        let cancelNotifier = scratchNotifier(center: cancelCenter)
        var reachedExplanation = false
        await hosted(cancelNotifier) {
            await flipSwitch(cancelNotifier)
            await waitUntil(timeout: 3) { cancelNotifier.stage == .prePermission }
            reachedExplanation = cancelNotifier.stage == .prePermission
            await clickSettled("settings.notify.cancel", label: String(localized: "settings.notifications.pre.cancel"))
            await waitUntil(timeout: 3) { cancelNotifier.stage == .idle }
        }
        record("notify[L3]: Cancel on the explanation keeps it off and the system is never asked",
               reachedExplanation && !cancelNotifier.isEnabled && cancelNotifier.stage == .idle && cancelCenter.requestCount == (breakMode ? 1 : 0),
               "reached=\(reachedExplanation) enabled=\(cancelNotifier.isEnabled) stage=\(cancelNotifier.stage) asked=\(cancelCenter.requestCount)")

        // L4: the system says no -> still off, and the hint with the Settings button is on screen.
        let refusedCenter = RecordingNotificationCenter(grantsOnRequest: false)
        let refusedNotifier = scratchNotifier(center: refusedCenter)
        var hintShown = false
        await hosted(refusedNotifier) {
            await flipSwitch(refusedNotifier)
            await waitUntil(timeout: 3) { refusedNotifier.stage == .prePermission }
            await clickSettled("settings.notify.continue", label: String(localized: "settings.notifications.pre.continue"))
            await waitUntil(timeout: 3) { refusedNotifier.stage == .refused }
            hintShown = await waitUntil(timeout: 3) { UITestAnchors.frames["settings.notify.opensettings"] != nil }
        }
        record("notify[L4]: a refused system prompt keeps it off and shows the System Settings hint",
               !refusedNotifier.isEnabled && refusedNotifier.stage == .refused && refusedCenter.requestCount == 1 && hintShown,
               "enabled=\(refusedNotifier.isEnabled) stage=\(refusedNotifier.stage) asked=\(refusedCenter.requestCount) hint=\(hintShown)")
    }

    // MARK: L9

    private static func hitTargets() async {
        let notifier = scratchNotifier(center: RecordingNotificationCenter())
        var frames: [String: CGRect] = [:]
        await hosted(notifier) {
            await notifier.setEnabled(true)
            await waitUntil(timeout: 3) { UITestAnchors.frames["settings.notify.continue"] != nil }
            await waitStable { UITestAnchors.frames["settings.notify.continue"] ?? .zero }
            frames = UITestAnchors.frames
        }
        let toggle = frames["settings.notify.toggle"] ?? .zero
        let cont = frames["settings.notify.continue"] ?? .zero
        let cancel = frames["settings.notify.cancel"] ?? .zero
        // The switch is the system control every Settings row uses (macOS minimum 20 pt); our buttons keep Metrics.minHit.
        let ok = toggle.width >= 20 && toggle.height >= 20
            && cont.width >= Metrics.minHit && cont.height >= Metrics.minHit
            && cancel.width >= Metrics.minHit && cancel.height >= Metrics.minHit
        record("notify[L9]: switch, Continue and Not now hit areas meet the minimum size",
               ok, "toggle=\(Int(toggle.width))x\(Int(toggle.height)) continue=\(Int(cont.width))x\(Int(cont.height)) cancel=\(Int(cancel.width))x\(Int(cancel.height))")
    }

    // MARK: L10

    private static func keyboardPath(breakMode: Bool) async {
        let center = RecordingNotificationCenter()
        let notifier = scratchNotifier(center: center)
        await hosted(notifier) {
            await notifier.setEnabled(true)
            await waitUntil(timeout: 3) { UITestAnchors.frames["settings.notify.continue"] != nil }
            _ = await ensureKey(window)
            key("\r", keyCode: 36)
            await waitUntil(timeout: 3) { notifier.isEnabled }
        }
        let returnWorked = notifier.isEnabled && center.requestCount == 1

        let escCenter = RecordingNotificationCenter()
        let escNotifier = scratchNotifier(center: escCenter)
        await hosted(escNotifier) {
            await escNotifier.setEnabled(true)
            await waitUntil(timeout: 3) { UITestAnchors.frames["settings.notify.cancel"] != nil }
            _ = await ensureKey(window)
            key("\u{1B}", keyCode: 53)
            await waitUntil(timeout: 3) { escNotifier.stage == .idle }
        }
        let escapeWorked = escNotifier.stage == .idle && !escNotifier.isEnabled && escCenter.requestCount == 0
        record("notify[L10]: Return continues and Escape cancels the explanation from the keyboard alone",
               (breakMode ? !returnWorked : returnWorked) && escapeWorked,
               "return=\(returnWorked) escape=\(escapeWorked)")
    }

    // MARK: L5 L6 L7

    /// A hand-written table of blocks against the clock 1_790_000_000 (all times are seconds from it).
    private static func planTable(_ model: AppModel, breakMode: Bool) async {
        let store = model.store
        let today = Day.today(calendar: KronosLocale.calendar)
        let b1 = calendarEvent("dn.b1", "Focus block", from: 1800)
        let b2 = calendarEvent("dn.b2", "Admin block", from: 3600)
        let b3 = calendarEvent("dn.b3", "Past block", from: -600)
        let b4 = calendarEvent("dn.b4", "Unlinked block", from: 7200)
        let b5 = calendarEvent("dn.b5", "Done block", from: 9000)
        let b6 = calendarEvent("dn.b6", "Tomorrow block", from: 30 * 3600)
        let b7 = calendarEvent("dn.b7", "Two tasks block", from: 10800)
        let b8 = calendarEvent("dn.b8", "Due block", from: 12000)
        let b9 = calendarEvent("dn.b9", "Aside block", from: 13000)
        let b10 = calendarEvent("dn.b10", "Linked and due block", from: 14000)
        let blocks = [b1, b2, b3, b4, b5, b6, b7, b8, b9, b10]

        let a = linkedTask(model, "dn plan A", to: b1, firstMove: "Draft the intro")
        let b = linkedTask(model, "dn plan send invoice", to: b2)
        let c = linkedTask(model, "dn plan past", to: b3, firstMove: "Never shown")
        let d = linkedTask(model, "dn plan done", to: b5, firstMove: "Never shown")
        store.completeNoUndo(d.id)
        let e = linkedTask(model, "dn plan tomorrow", to: b6, firstMove: "Never shown")
        let f1 = linkedTask(model, "dn plan two one", to: b7, firstMove: "First of two")
        let f2 = linkedTask(model, "dn plan two two", to: b7, firstMove: "Second of two")
        let dueOnly = store.createNoUndo(title: "dn plan due only", dueDay: today)
        let aside = linkedTask(model, "dn plan aside", to: b9, firstMove: "Never shown")
        ImpulsDayMemory.setAside(aside.id, today: today)
        let linkedDue = linkedTask(model, "dn plan linked and due", to: b10, firstMove: "Write the summary", dueDay: today)
        _ = (c, e, dueOnly)
        model.didMutate()

        let center = RecordingNotificationCenter(status: .authorized)
        let clock = FixtureClock(now: fixtureStart)
        let notifier = scratchNotifier(center: center, clock: clock, model: model)
        notifier.blockSource = { blocks }
        await notifier.setEnabled(true)

        // L5: exactly the hand-written expectation, titled "Start: <first move>" at the block start.
        let got = center.scheduled
        let expectedIDs = ["kronos.blockstart.dn.b1", "kronos.blockstart.dn.b10", "kronos.blockstart.dn.b2", "kronos.blockstart.dn.b7"]
        let r1 = got["kronos.blockstart.dn.b1"]
        let r2 = got["kronos.blockstart.dn.b2"]
        let r7 = got["kronos.blockstart.dn.b7"]
        let r10 = got["kronos.blockstart.dn.b10"]
        let titlesRight = r1?.title == "Start: Draft the intro" && r2?.title == "Start: dn plan send invoice"
            && r10?.title == "Start: Write the summary"
        let timesRight = r1?.fireDate == b1.event.start && r2?.fireDate == b2.event.start && r10?.fireDate == b10.event.start
        let bodiesRight = r1?.body == "Focus block" && r2?.body == "Admin block"
        let oneForTwoTasks = r7.map { [f1.id, f2.id].contains($0.taskID) } ?? false
        let linkedRight = r1?.taskID == a.id && r2?.taskID == b.id && r10?.taskID == linkedDue.id
        let idsRight = Array(got.keys.sorted()) == (breakMode ? Array(expectedIDs.dropLast()) : expectedIDs)
        let scheduledOnce = center.scheduleCount
        await notifier.refresh()
        let quiet = center.scheduleCount == scheduledOnce
        record("notify[L5]: only future blocks with a directly linked open task schedule, titled Start: first move, at the block start",
               idsRight && titlesRight && timesRight && bodiesRight && oneForTwoTasks && linkedRight && quiet,
               "ids=\(got.keys.sorted()) titles=\(titlesRight) times=\(timesRight) bodies=\(bodiesRight) oneOfTwo=\(oneForTwoTasks) linked=\(linkedRight) quietRefresh=\(quiet)")

        // L6: nothing for a task that only has a due date, nor for one set aside for today, and a
        // linked task with a due date still gets exactly the start notification and no second one.
        let none = got["kronos.blockstart.dn.b8"] == nil && got["kronos.blockstart.dn.b9"] == nil
        let dueNotifications = got.values.filter { $0.taskID == dueOnly.id }.count
        let linkedDueCount = got.values.filter { $0.taskID == linkedDue.id }.count
        record("notify[L6]: a due date alone and a task set aside today produce nothing; a linked task with a due date gets only its start notification",
               none && dueNotifications == 0 && linkedDueCount == 1,
               "dueBlock=\(got["kronos.blockstart.dn.b8"] == nil) asideBlock=\(got["kronos.blockstart.dn.b9"] == nil) dueOnly=\(dueNotifications) linkedDue=\(linkedDueCount)")

        // Completing a linked task drops its pending notification at the next refresh.
        store.completeNoUndo(a.id)
        await notifier.refresh()
        let droppedAfterDone = center.scheduled["kronos.blockstart.dn.b1"] == nil && center.scheduled["kronos.blockstart.dn.b2"] != nil

        // L7: turning it off removes everything and a later refresh schedules nothing.
        let before = center.scheduleCount
        await notifier.setEnabled(false)
        let emptied = center.scheduled.isEmpty
        await notifier.refresh()
        record("notify[L7]: turning it off removes every pending notification and nothing is scheduled again; a finished task drops out first",
               droppedAfterDone && emptied && !notifier.isEnabled && center.scheduleCount == before && center.scheduled.isEmpty,
               "droppedAfterDone=\(droppedAfterDone) emptied=\(emptied) enabled=\(notifier.isEnabled) scheduleDelta=\(center.scheduleCount - before)")

        for t in [a, b, c, d, e, f1, f2, dueOnly, aside, linkedDue] { store.softDeleteNoUndo(t.id) }
        model.didMutate()
    }

    // MARK: L8

    private static func taskFingerprint(_ model: AppModel) -> String {
        model.store.allTasks().map { "\($0.id)|\($0.sortIndex)|\($0.statusRaw)|\($0.notes)|\($0.title)" }.sorted().joined(separator: "\n")
    }

    private static func actions(_ model: AppModel, breakMode: Bool) async {
        let store = model.store
        let today = Day.today(calendar: KronosLocale.calendar)
        let t1 = store.createNoUndo(title: "dn action done")
        let t2 = store.createNoUndo(title: "dn action not now")
        let t3 = store.createNoUndo(title: "dn action open")
        model.didMutate()
        let center = RecordingNotificationCenter(status: .authorized)
        let notifier = scratchNotifier(center: center, model: model)
        _ = notifier.center   // wires onAction like the first schedule does

        let depth0 = store.undoDepth
        center.simulate(.done, taskID: t1.id)
        let doneOnce = store.task(t1.id)?.status == (breakMode ? .todo : .done) && store.undoDepth == depth0 + 1
        let depth1 = store.undoDepth
        center.simulate(.done, taskID: t1.id)
        let secondDoneNoop = store.undoDepth == depth1

        let beforeNotNow = taskFingerprint(model)
        let depth2 = store.undoDepth
        center.simulate(.notNow, taskID: t2.id)
        let notNowWritesNothing = taskFingerprint(model) == beforeNotNow && store.undoDepth == depth2
        let setAside = ImpulsDayMemory.setAsideToday(among: [t2.id], today: today).contains(t2.id)

        model.selectedTaskID = nil
        center.simulate(.open, taskID: t3.id)
        let opened = model.selectedTaskID == t3.id

        let beforeGone = taskFingerprint(model)
        center.simulate(.done, taskID: UUID())
        let goneNoop = taskFingerprint(model) == beforeGone

        record("notify[L8]: Done completes in one undo step and again does nothing; Not now writes nothing and sets the task aside; Open selects it; a gone task is ignored",
               doneOnce && secondDoneNoop && notNowWritesNothing && setAside && opened && goneNoop,
               "done=\(doneOnce) secondNoop=\(secondDoneNoop) notNowNoWrite=\(notNowWritesNothing) aside=\(setAside) opened=\(opened) goneNoop=\(goneNoop)")

        for t in [t1, t2, t3] { store.softDeleteNoUndo(t.id) }
        model.selectedTaskID = nil
        model.didMutate()
    }
}
#endif
