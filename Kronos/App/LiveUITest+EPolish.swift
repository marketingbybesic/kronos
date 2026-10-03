// Live steps for the follow-up fixes: Start's notes request focusing the notes editor, notes and
// waits-on saves that keep another device's change, the triage lease, the undo pill holding while
// hovered, the morning card's Return and Esc, the on-task stint across a relaunch, and Pick one
// never offering a proposal that waits for review. Run alone with `--only group:E-POLISH`.
#if !RELEASE
import AppKit
import KronosCore

@MainActor
extension LiveUITest {
    static func ePolishSteps(_ model: AppModel) async {
        let breakMode = ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil
        await setWindowSize(width: 1500, height: 900)
        await runStep(model, scope: .all) { await ePolishNotesFocusAndConflict($0, breakMode: breakMode) }
        await runStep(model, scope: .all) { await ePolishWaitsOnChip($0) }
        await runStep(model, scope: .all) { await ePolishTitleFocusAndEsc($0, breakMode: breakMode) }
        await runStep(model, scope: .all) { await ePolishTriageLease($0, breakMode: breakMode) }
        await runStep(model, scope: .all) { await ePolishUndoPillHold($0, breakMode: breakMode) }
        await runStep(model, scope: .today) { await ePolishMorningKeys($0, breakMode: breakMode) }
        await runStep(model, scope: .all) { _ in ePolishStintAcrossRelaunch(breakMode: breakMode) }
        await runStep(model, scope: .all) { ePolishPendingNeverPicked($0) }
        await resetState(model)
    }

    // MARK: Notes

    /// Start's request puts the cursor in that task's notes; then a save made while another device
    /// changed the same notes keeps both texts under the conflict header, as one undo step.
    private static func ePolishNotesFocusAndConflict(_ model: AppModel, breakMode: Bool) async {
        let store = model.store
        let other = store.create(title: "Notes focus bystander")
        let target = store.create(title: "Notes focus probe", notes: "Agenda from Monday")
        model.didMutate()
        model.selectedTaskID = other.id
        await settle(400)
        defer { store.softDeleteNoUndo(other.id); store.softDeleteNoUndo(target.id); model.didMutate() }

        NotificationCenter.default.post(name: .kronosFocusNotesRequested, object: nil, userInfo: ["taskID": target.id])
        let focused = await waitUntil(timeout: 3) {
            (window.firstResponder as? NSTextView)?.string == "Agenda from Monday"
        }
        record("Start's notes request selects that task and puts the cursor in its notes",
               focused && model.selectedTaskID == target.id,
               "focused=\(focused) selected=\(model.selectedTaskID == target.id) responder=\(String(describing: type(of: window.firstResponder as Any)))")
        guard focused, let editor = window.firstResponder as? NSTextView else { return }

        // Type at the end, then another device saves into the same notes before the autosave runs.
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        await typeText(" ok")
        await settle(120)
        store.updateNoUndo(target.id) { $0.notes = "Agenda from Monday\n\nRoom changed to 4B" }
        model.didMutate()
        await settle(120)
        let depth = store.undoDepth
        NotificationCenter.default.post(name: .kronosFlushDrafts, object: nil)
        await settle(400)
        let notes = store.task(target.id)?.notes ?? ""
        let header = String(localized: "detail.notes.conflict.header")
        let keptMine = notes.contains("Agenda from Monday ok")
        let keptTheirs = notes.contains("Room changed to 4B")
        let headed = notes.contains(header)
        record("a notes save keeps the text another device saved meanwhile, under the conflict header, in one undo step",
               keptMine && (breakMode ? !keptTheirs : keptTheirs) && headed && store.undoDepth == depth + 1,
               "mine=\(keptMine) theirs=\(keptTheirs) header=\(headed) steps=\(store.undoDepth - depth) notes=\(notes.debugDescription)")
        let shown = await waitUntil(timeout: 2) { editor.string.contains("Room changed to 4B") }
        record("after the merged save the editor shows the merged notes", shown, "editor=\(editor.string.debugDescription)")
        window.makeFirstResponder(nil)
    }

    /// The waits-on chip removes through the conflict-safe save: a blocker another device added
    /// meanwhile stays, the clicked one goes.
    private static func ePolishWaitsOnChip(_ model: AppModel) async {
        let store = model.store
        let a = store.create(title: "Blocker alpha")
        let c = store.create(title: "Blocker gamma")
        let t = store.create(title: "Waits-on probe")
        _ = store.setWaitsOn(t.id, [a.id])
        // The Waits on row lives under Details.
        let detailsKey = "kronos.inspector.detailsOpen"
        let detailsWasOpen = UserDefaults.standard.bool(forKey: detailsKey)
        UserDefaults.standard.set(true, forKey: detailsKey)
        model.didMutate()
        model.selectedTaskID = t.id
        await settle(600)
        defer {
            UserDefaults.standard.set(detailsWasOpen, forKey: detailsKey)
            for id in [a.id, c.id, t.id] { store.softDeleteNoUndo(id) }
            model.didMutate()
        }
        _ = store.setWaitsOnNoUndo(t.id, [a.id, c.id])   // the other device
        model.didMutate()
        await settle(400)
        let clicked = await click("inspector.waitson.chip.Blocker alpha")
        let done = await waitUntil(timeout: 2) { store.task(t.id)?.waitsOn == [c.id] }
        record("removing a waits-on chip keeps the blocker another device added",
               clicked && done, "clicked=\(clicked) waitsOn=\(store.task(t.id)?.waitsOn.count ?? -1)")
    }

    // MARK: Title

    /// The list's request (Return on a row) puts the cursor in the inspector title; Esc there keeps
    /// what was typed and gives the keys back to the list.
    private static func ePolishTitleFocusAndEsc(_ model: AppModel, breakMode: Bool) async {
        let store = model.store
        let t = store.create(title: "Title probe")
        model.didMutate()
        model.selectedTaskID = t.id
        await settle(500)
        defer { store.softDeleteNoUndo(t.id); model.didMutate() }
        NotificationCenter.default.post(name: UIRequests.focusInspectorTitle, object: nil, userInfo: ["taskID": t.id])
        let focused = await waitUntil(timeout: 3) { (window.firstResponder as? NSTextView)?.string == "Title probe" }
        record("the list's title request puts the cursor in the inspector title",
               focused, "responder=\(String(describing: type(of: window.firstResponder as Any)))")
        guard focused, let editor = window.firstResponder as? NSTextView else { return }
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        await typeText(" v2")
        await settle(150)
        key("\u{1B}", keyCode: 53)
        let saved = await waitUntil(timeout: 2) { store.task(t.id)?.title == "Title probe v2" }
        let left = !(window.firstResponder is NSTextView)
        record("Esc in the inspector title saves what was typed and leaves the field",
               (breakMode ? !saved : saved) && left,
               "title=\(store.task(t.id)?.title ?? "nil") leftField=\(left)")
    }

    // MARK: Triage lease

    /// A live claim held by another device stops this one from triaging the task; once that claim
    /// has expired, triage runs and gives the lease back.
    private static func ePolishTriageLease(_ model: AppModel, breakMode: Bool) async {
        let store = model.store
        // The live test launch returns before the app starts its own service: run one here, the
        // same class the app runs, with no model answering (nothing may reach the network).
        let triage = AutoTriage(model: model)
        triage.start()
        let priorAI = model.ai
        model.ai = nil
        let t = store.create(title: "Call the plumber about the leak")
        model.didMutate()
        defer {
            triage.stop()
            model.ai = priorAI
            store.softDeleteNoUndo(t.id)
            model.didMutate()
        }
        let held = store.claimTriageLease(t.id, owner: "other-mac.1")
        triage.triage(t.id, fillOnly: false)
        await settle(1500)
        let skipped = store.task(t.id)?.triagedAt == nil && store.triageLeaseHolder(t.id) == "other-mac.1"
        record("triage leaves a task alone while another device holds its lease",
               held && (breakMode ? !skipped : skipped),
               "held=\(held) triagedAt=\(String(describing: store.task(t.id)?.triagedAt)) holder=\(store.triageLeaseHolder(t.id) ?? "nil")")

        // The other device's claim runs out: the same claim, dated past its duration.
        store.claimTriageLease(t.id, owner: "other-mac.1", now: Date().addingTimeInterval(-(TriageLease.duration + 60)))
        triage.triage(t.id, fillOnly: false)
        let ran = await waitUntil(timeout: 6) { store.task(t.id)?.triagedAt != nil }
        let released = store.triageLeaseHolder(t.id) == nil && store.task(t.id)?.triageLeaseOwner == nil
        record("after the claim expires triage runs and gives the lease back",
               ran && released, "ran=\(ran) holder=\(store.task(t.id)?.triageLeaseOwner ?? "nil")")
    }

    // MARK: Undo pill

    /// Hovering the pill (the same hold VoiceOver focus applies) stops its 5 s timeout; leaving it
    /// lets the rest of the window run out. The clock itself against a hand table.
    private static func ePolishUndoPillHold(_ model: AppModel, breakMode: Bool) async {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        var clock = UndoPillCountdown(duration: 5)
        clock.resume(at: t0)
        let a = clock.remaining(at: t0.addingTimeInterval(2))            // 3 left
        clock.pause(at: t0.addingTimeInterval(2))
        let b = clock.remaining(at: t0.addingTimeInterval(60))           // still 3 while paused
        clock.resume(at: t0.addingTimeInterval(60))
        let c = clock.remaining(at: t0.addingTimeInterval(62.5))         // 0.5 left
        let d = clock.remaining(at: t0.addingTimeInterval(70))           // never below 0
        let f = clock.fraction(at: t0.addingTimeInterval(61))            // 2 of 5
        let table = abs(a - 3) < 0.001 && abs(b - 3) < 0.001 && abs(c - 0.5) < 0.001 && d == 0 && abs(f - 0.4) < 0.001
        record("undo pill clock: pause keeps the time left, resume drains the rest (hand table)",
               table, "a=\(a) b=\(b) c=\(c) d=\(d) f=\(f)")

        UndoToastCenter.shared.dismiss()
        await waitUntil(timeout: 2) { UITestAnchors.frames["undo.pill"] == nil }
        await settle(300)
        KUndoPill.liveHold = nil
        UndoToastCenter.shared.show("Hold probe")
        let shown = await waitUntil(timeout: 2) { UITestAnchors.frames["undo.pill"] != nil && KUndoPill.liveHold != nil }
        KUndoPill.liveHold?(true)
        await settle(6500)
        let stayed = UndoToastCenter.shared.current?.message == "Hold probe"
        let released = Date()
        KUndoPill.liveHold?(false)
        let gone = await waitUntil(timeout: 8) { UndoToastCenter.shared.current == nil }
        let after = Date().timeIntervalSince(released)
        record("a held undo pill outlives its 5 s window and expires with the rest of it once released",
               shown && (breakMode ? !stayed : stayed) && gone && after > 3,
               "shown=\(shown) stayed=\(stayed) gone=\(gone) afterRelease=\(String(format: "%.1f", after))s")
    }

    // MARK: Morning card

    /// Keyboard only: Esc closes the morning card without starting anything; Return on a fresh
    /// card starts row 1. A proposal waiting for review is never one of its rows.
    private static func ePolishMorningKeys(_ model: AppModel, breakMode: Bool) async {
        let store = model.store
        let hidden = store.allTasks().map(\.id)
        for id in hidden { store.softDeleteNoUndo(id) }
        var planted: [UUID] = []
        func plant(_ title: String, _ priority: KPriority, review: Int = 0) -> KTask {
            let t = store.create(title: title, notes: "", project: nil, status: .todo, priority: priority, dueDay: nil)
            store.setDepth(t.id, .shallow)
            if review != 0 { store.updateNoUndo(t.id) { $0.reviewRaw = review } }
            planted.append(t.id)
            return t
        }
        let pending = plant("Agent proposal: renew the domain", .urgent, review: 1)
        let a = plant("Morning keys A", .high)
        _ = plant("Morning keys B", .medium)
        _ = plant("Morning keys C", .low)
        ImpulsEnergyMemory.rememberToday(.mid)
        model.didMutate()
        defer {
            for id in planted { store.softDeleteNoUndo(id) }
            for id in hidden { store.restoreNoUndo(id) }
            model.pinnedFocusTaskID = nil
            model.didMutate()
        }
        let today = Day.today(calendar: KronosLocale.calendar)
        let pool = MorningPlan.pool(model: model, energy: .mid, today: today).map(\.id)
        record("the morning card never lists a proposal waiting for review",
               !pool.contains(pending.id) && pool.first == a.id, "pool=\(pool.count) first=\(pool.first == a.id) pending=\(pool.contains(pending.id))")

        NotificationCenter.default.post(name: .kronosMorningPlanRequested, object: nil)
        let open1 = await waitUntil(timeout: 4) { UITestAnchors.frames["morning.card"] != nil }
        await settle(500)
        let closed = await keyUntil("\u{1B}", keyCode: 53) { UITestAnchors.frames["morning.card"] == nil }
        let untouched = store.task(a.id)?.status == .todo
        record("Esc on the focused morning card closes it and starts nothing",
               open1 && closed && untouched, "open=\(open1) closed=\(closed) untouched=\(untouched)")

        NotificationCenter.default.post(name: .kronosMorningPlanRequested, object: nil)
        let open2 = await waitUntil(timeout: 4) { UITestAnchors.frames["morning.card"] != nil }
        await settle(500)
        let started = await keyUntil("\r", keyCode: 36) { store.task(a.id)?.status == .inProgress }
        let gone = await waitUntil(timeout: 3) { UITestAnchors.frames["morning.card"] == nil }
        record("Return on the focused morning card starts row 1 and closes the card",
               open2 && (breakMode ? !started : started) && gone,
               "open=\(open2) started=\(started) gone=\(gone)")
    }

    /// Presses a key on the key window until `effect` holds, twice at most (the card takes the
    /// focus back from the list a beat after it mounts).
    private static func keyUntil(_ chars: String, keyCode: UInt16, _ effect: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<2 {
            await ensureKey()
            key(chars, keyCode: keyCode)
            if await waitUntil(timeout: 1.5, effect) { return true }
        }
        return false
    }

    // MARK: On-task stint

    /// The "been at this a while" stint survives a relaunch on the same day and starts over on a
    /// new one. Hand table against a fixture clock and a scratch defaults suite.
    private static func ePolishStintAcrossRelaunch(breakMode: Bool) {
        let suite = "kronos.uitest.stint." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else {
            record("on-task stint: scratch defaults open", false, "suite=\(suite)")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let pin = UUID()
        let start = Date(timeIntervalSince1970: 1_790_000_000)   // 2026-09-21 16:53 UTC, 18:53 Zagreb
        let clock = FixtureClock(now: start)
        let first = MenuBarQuiet(clock: clock, stintDefaults: defaults)
        first.tick(pinnedID: pin)
        clock.now = start.addingTimeInterval(40 * 60)
        let relaunched = MenuBarQuiet(clock: clock, stintDefaults: defaults)
        relaunched.tick(pinnedID: pin)
        let kept = relaunched.stintStart == start
        clock.now = start.addingTimeInterval(90 * 60)
        relaunched.tick(pinnedID: pin)
        let due = relaunched.isLongOnTaskDue
        let nextDay = FixtureClock(now: start.addingTimeInterval(20 * 3600))
        let tomorrow = MenuBarQuiet(clock: nextDay, stintDefaults: defaults)
        let fresh = tomorrow.stintStart == nil
        let memoryOnly = MenuBarQuiet(clock: clock, stintDefaults: nil).stintStart == nil
        record("the 90 min on-task stint survives a relaunch the same day and starts over the next day",
               (breakMode ? !kept : kept) && due && fresh && memoryOnly,
               "kept=\(kept) dueAt90=\(due) freshNextDay=\(fresh) memoryOnly=\(memoryOnly)")
    }

    // MARK: Pick one

    /// Pick one's query drops a proposal waiting for review even when the ranking engine it is
    /// given would offer it first.
    private static func ePolishPendingNeverPicked(_ model: AppModel) {
        guard let store = try? TaskStore(inMemory: true) else {
            record("Pick one pending: isolated store opens", false, "TaskStore(inMemory:) threw")
            return
        }
        let pending = store.create(title: "Agent proposal")
        store.update(pending.id) { $0.reviewRaw = 1 }
        let mine = store.create(title: "My own task")
        let engine = EveryTaskEngine()
        let picks = ImpulsQuery.candidates(engine: engine, energy: .mid, excluding: [], tasks: store.allTasks(),
                                           today: Day.today(), count: 3).map(\.taskID)
        let real = ImpulsQuery.candidates(engine: RankingEngine(), energy: .mid, excluding: [], tasks: store.allTasks(),
                                          today: Day.today(), count: 3).map(\.taskID)
        record("Pick one never offers a proposal waiting for review, whatever the engine ranks",
               picks == [mine.id] && real == [mine.id], "stub=\(picks.count) real=\(real.count)")
    }

    /// A ranking engine that offers every task in order, pending or not.
    private struct EveryTaskEngine: RankingProviding {
        func candidates(energy: KEnergyLevel, count: Int, maxDeep: Bool, today: Int, tasks: [KTask]) -> [Candidate] {
            tasks.sorted { $0.reviewRaw > $1.reviewRaw }.prefix(count).map { Candidate(taskID: $0.id, reason: "stub") }
        }
    }
}
#endif
