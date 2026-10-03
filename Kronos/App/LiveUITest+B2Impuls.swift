// Live steps for Pick one, the morning plan and the Now card actions. Run alone with `--only group:B2-IMPULS`.
// Every step hides the tasks that were already there, plants its own, and puts everything back.
#if !RELEASE
import AppKit
import KronosCore

@MainActor
extension LiveUITest {
    /// Plants probe tasks and removes them again.
    @MainActor
    final class ImpulsProbe {
        let model: AppModel
        var planted: [UUID] = []
        init(_ model: AppModel) { self.model = model }
        var store: TaskStore { model.store }

        @discardableResult
        func plant(_ title: String, notes: String = "", project: KProject? = nil, priority: KPriority = .none,
                   due: Int? = nil, effort: KEffort = .none, dread: Bool = false) -> KTask {
            let t = store.create(title: title, notes: notes, project: project, status: .todo, priority: priority, dueDay: due)
            store.setDepth(t.id, .shallow)
            if effort != .none { store.updateNoUndo(t.id) { $0.effort = effort } }
            if dread { store.setDread(t.id, true) }
            planted.append(t.id)
            return t
        }

        func clear() async {
            model.isImpulsOpen = false
            for id in planted { store.softDeleteNoUndo(id) }
            planted = []
            model.pinnedFocusTaskID = nil
            model.selectedTaskID = nil
            model.didMutate()
            await settle(250)
        }
    }

    static func b2ImpulsSteps(_ model: AppModel) async {
        let store = model.store
        let hidden = store.allTasks().map(\.id)
        for id in hidden { store.softDeleteNoUndo(id) }
        model.didMutate()
        let probe = ImpulsProbe(model)
        let breakMode = ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil
        let today = Day.today(calendar: KronosLocale.calendar)
        await setWindowSize(width: 1500, height: 900)
        ImpulsEnergyMemory.rememberToday(.mid)

        await morningReturn(probe, breakMode: breakMode, today: today)
        await probe.clear()
        await morningSunday(probe, breakMode: breakMode)
        await probe.clear()
        await impulsStartAndSetAside(probe, breakMode: breakMode, today: today)
        await probe.clear()
        await impulsDreadServing(probe, today: today)
        await probe.clear()
        await impulsLargeBreakdown(probe, breakMode: breakMode)
        await probe.clear()
        await impulsGenericStart(probe)
        await probe.clear()
        await impulsFirstMoveLink(probe)
        await probe.clear()
        await nowCardActions(probe, today: today)
        await probe.clear()
        await undoPillPrimary(probe)
        await probe.clear()

        for id in hidden { store.restoreNoUndo(id) }
        model.didMutate()
    }

    private static func openImpuls(_ model: AppModel) async -> Bool {
        model.isImpulsOpen = true
        let shown = await waitUntil(timeout: 4) { UITestAnchors.frames["impuls.hero"] != nil || UITestAnchors.frames["impuls.empty"] != nil }
        await settle(300)
        return shown
    }

    private static func returnKey() { key("\r", keyCode: 36) }

    /// Presses Return and waits for the effect; a key lost while the freshly opened card was still taking
    /// focus is sent once more. Returns true when the second press was needed (reported in the detail).
    @discardableResult
    private static func returnUntil(timeout: TimeInterval = 3, _ effect: @MainActor () -> Bool) async -> Bool {
        await ensureKey()
        returnKey()
        if await waitUntil(timeout: 1.5, effect) { return false }
        await ensureKey()
        returnKey()
        await waitUntil(timeout: timeout, effect)
        return true
    }

    // MARK: Morning plan

    /// Return on the inline morning card: row 1 in progress and pinned, the three planned for today, no
    /// deadline touched, the list scope unchanged, one undo step. Keyboard only.
    private static func morningReturn(_ p: ImpulsProbe, breakMode: Bool, today: Int) async {
        let model = p.model, store = p.store
        model.scope = .today
        let a = p.plant("Morning probe A", priority: .urgent, due: today + 3)
        let b = p.plant("Morning probe B", priority: .high)
        let c = p.plant("Morning probe C", priority: .low)
        model.didMutate()
        let dueBefore = [a.id: a.dueDay, b.id: b.dueDay, c.id: c.dueDay]
        let depth = store.undoDepth
        NotificationCenter.default.post(name: .kronosMorningPlanRequested, object: nil)
        let shown = await waitUntil(timeout: 4) { UITestAnchors.frames["morning.card"] != nil }
        record("morning plan card appears inline above the list", shown, "anchor=\(UITestAnchors.frames["morning.card"] != nil)")
        await settle(500)
        let retriedA = await returnUntil { store.task(a.id)?.status == .inProgress }
        let started = store.task(a.id)?.status == .inProgress
        let pinned = model.pinnedFocusTaskID == a.id
        let others = [b.id, c.id].allSatisfy { store.task($0)?.status == .todo }
        let dueKept = [a.id, b.id, c.id].allSatisfy { store.task($0)?.dueDay == dueBefore[$0]! }
        let planned = [a.id, b.id, c.id].allSatisfy { store.task($0)?.plannedDay == today }
        let oneStep = store.undoDepth == depth + 1
        let gone = await waitUntil(timeout: 3) { UITestAnchors.frames["morning.card"] == nil }
        record("Return on the morning card starts row 1: in progress, pinned, the others untouched",
               started && pinned && others, "started=\(started) pinned=\(pinned) others=\(others) retried=\(retriedA)")
        // Break mode expects a changed deadline, which never happens: the run must fail here.
        record("Let's go writes the planned day and never a due date, in one undo step",
               breakMode ? !dueKept : (dueKept && planned && oneStep),
               "dueKept=\(dueKept) planned=\(planned) steps=\(store.undoDepth - depth)")
        record("the morning card closes after Let's go and the scope stays Today", gone && model.scope == .today,
               "gone=\(gone) scope=\(model.scope)")
    }

    // MARK: Sunday sweep entry

    /// Only on a Sunday the morning card offers Sweep; clicking it opens the Sweep sitting and closes the card.
    private static func morningSunday(_ p: ImpulsProbe, breakMode: Bool) async {
        let model = p.model
        defer { MorningPlan.weekdayOverride = nil }
        model.scope = .today
        for (i, title) in ["Sunday probe A", "Sunday probe B", "Sunday probe C"].enumerated() {
            p.plant(title, priority: i == 0 ? .urgent : .high)
        }
        model.didMutate()
        MorningPlan.weekdayOverride = 3
        NotificationCenter.default.post(name: .kronosMorningPlanRequested, object: nil)
        await waitUntil(timeout: 4) { UITestAnchors.frames["morning.card"] != nil }
        await settle(300)
        let midweek = UITestAnchors.frames["morning.sweep"] != nil
        // Close the card, then reopen it on a Sunday.
        _ = await click("morning.dismiss")
        await waitUntil(timeout: 3) { UITestAnchors.frames["morning.card"] == nil }
        MorningPlan.weekdayOverride = 1
        NotificationCenter.default.post(name: .kronosMorningPlanRequested, object: nil)
        await waitUntil(timeout: 4) { UITestAnchors.frames["morning.sweep"] != nil }
        let sunday = UITestAnchors.frames["morning.sweep"] != nil
        let token = TriageLaunch.shared.token
        _ = await click("morning.sweep")
        await waitUntil(timeout: 3) { model.isTriageOpen }
        let opened = model.isTriageOpen
        let requested = TriageLaunch.shared.token == token + 1
        let cardGone = await waitUntil(timeout: 3) { UITestAnchors.frames["morning.card"] == nil }
        record("the morning card offers Sweep on Sunday only, and it opens the Sweep sitting",
               breakMode ? midweek : (!midweek && sunday && opened && requested && cardGone),
               "midweekOffered=\(midweek) sundayOffered=\(sunday) opened=\(opened) requested=\(requested) cardGone=\(cardGone)")
        model.isTriageOpen = false
        await settle(300)
    }

    // MARK: Pick one: Start keeps the list, Not now sets a task aside for today

    private static func impulsStartAndSetAside(_ p: ImpulsProbe, breakMode: Bool, today: Int) async {
        let model = p.model, store = p.store
        // Start keeps the scope even for a task that lives in a project.
        let project = store.createProject(name: "Impuls probe project", colorHex: "#8224E3", icon: nil, area: nil)
        let t1 = p.plant("Impuls start probe", project: project, priority: .urgent)
        model.scope = .inbox
        model.didMutate()
        let opened = await openImpuls(model)
        let retried1 = await returnUntil { store.task(t1.id)?.status == .inProgress }
        record("Return on the Pick one card starts the task and keeps the list the person was in",
               opened && store.task(t1.id)?.status == .inProgress && model.pinnedFocusTaskID == t1.id
                   && model.scope == .inbox && !model.isImpulsOpen,
               "opened=\(opened) status=\(String(describing: store.task(t1.id)?.status)) scope=\(model.scope) pinned=\(model.pinnedFocusTaskID == t1.id) retried=\(retried1)")
        await p.clear()

        // Not now: set aside for today, the next card is the other task.
        let t2 = p.plant("Impuls set aside probe", priority: .urgent)
        let t3 = p.plant("Impuls next probe", priority: .low)
        model.scope = .inbox
        model.didMutate()
        _ = await openImpuls(model)
        _ = await click("impuls.notnow")
        await waitUntil(timeout: 3) { !model.isImpulsOpen }
        await settle(500)
        let aside = ImpulsNotNow.isExcluded(t2.id, today: today, in: KronosEnv.defaults)
        let tomorrow = ImpulsNotNow.isExcluded(t2.id, today: today + 1, in: KronosEnv.defaults)
        _ = await openImpuls(model)
        await returnUntil { store.task(t3.id)?.status == .inProgress }
        let nextStarted = store.task(t3.id)?.status == .inProgress
        let t2Untouched = store.task(t2.id)?.status == .todo
        record("Not now sets the task aside for today only; Pick one then offers the other task",
               breakMode ? t2Untouched == false : (aside && !tomorrow && nextStarted && t2Untouched),
               "aside=\(aside) tomorrowExcluded=\(tomorrow) nextStarted=\(nextStarted) t2Untouched=\(t2Untouched)")
    }

    // MARK: Dread serving

    /// The dread task leads once; the next pick is not a dread task; the memory is written the moment a
    /// card is shown.
    private static func impulsDreadServing(_ p: ImpulsProbe, today: Int) async {
        let model = p.model
        ImpulsDefaults.saveDread(servedDay: nil, lastWasDread: false, to: KronosEnv.defaults)
        p.plant("Dread serving probe dread", priority: .high, dread: true)
        p.plant("Dread serving probe plain", priority: .high)
        model.scope = .inbox
        model.didMutate()
        _ = await openImpuls(model)
        let first = ImpulsDefaults.loadDread(KronosEnv.defaults)
        model.isImpulsOpen = false
        await settle(300)
        _ = await openImpuls(model)
        let second = ImpulsDefaults.loadDread(KronosEnv.defaults)
        record("a dread task leads the first pick of the day and the pick is remembered",
               first.servedDay == today && first.lastWasDread, "served=\(String(describing: first.servedDay)) last=\(first.lastWasDread)")
        record("the pick after a dread pick is not a dread task, and today's serving stays recorded",
               second.servedDay == today && !second.lastWasDread, "served=\(String(describing: second.servedDay)) last=\(second.lastWasDread)")
    }

    // MARK: Large task

    private static func impulsLargeBreakdown(_ p: ImpulsProbe, breakMode: Bool) async {
        let model = p.model, store = p.store
        let big = p.plant("Large breakdown probe", notes: "Numbers are in the sheet", priority: .urgent, effort: .l)
        model.scope = .inbox
        model.didMutate()
        let depth = store.undoDepth
        _ = await openImpuls(model)
        await waitUntil(timeout: 3) { !(store.task(big.id)?.orderedChildren.isEmpty ?? true) }
        let steps = store.task(big.id)?.orderedChildren ?? []
        let titles = steps.map(\.title)
        let first = store.task(big.id)?.nextOpenSubtask?.title
        let silent = store.undoDepth == depth
        model.isImpulsOpen = false
        await settle(300)
        _ = await openImpuls(model)
        let again = store.task(big.id)?.orderedChildren.count ?? 0
        let filler = titles.contains { $0.lowercased().contains("mark the task finished") }
        record("a Large task with no steps gets 3 to 7 steps when Pick one serves it, the first is its first move, no filler, no undo step",
               breakMode ? steps.isEmpty : ((3...7).contains(steps.count) && first == titles.first && !filler && silent),
               "count=\(steps.count) first=\(first ?? "nil") filler=\(filler) silent=\(silent)")
        record("the breakdown runs once: serving the task again adds nothing", again == steps.count, "before=\(steps.count) after=\(again)")
    }

    // MARK: Generic first move

    private static func impulsGenericStart(_ p: ImpulsProbe) async {
        let model = p.model, store = p.store
        let g = p.plant("Tax return for Globex", notes: "Accountant sent the forms", priority: .urgent)
        model.scope = .inbox
        model.didMutate()
        final class Box: @unchecked Sendable { var id: UUID? }
        let box = Box()
        let token = NotificationCenter.default.addObserver(forName: .kronosFocusNotesRequested, object: nil, queue: .main) { n in
            box.id = n.userInfo?["taskID"] as? UUID
        }
        defer { NotificationCenter.default.removeObserver(token) }
        let opened = await openImpuls(model)
        let hadHero = UITestAnchors.frames["impuls.hero"] != nil
        let retriedG = await returnUntil { box.id != nil }
        var clicked = false
        if box.id == nil {
            // Diagnostic only: does Start work by click when the key did nothing?
            _ = await click("impuls.start")
            clicked = await waitUntil(timeout: 2) { box.id != nil }
        }
        let responder = String(describing: type(of: window.firstResponder as Any))
        let posted = box.id
        record("Start on a generic first move asks the inspector to focus that task's notes",
               posted == g.id, "posted=\(posted == g.id) opened=\(opened) hero=\(hadHero) status=\(String(describing: store.task(g.id)?.status)) open=\(model.isImpulsOpen) retried=\(retriedG) startByClick=\(clicked) responder=\(responder)")
    }

    // MARK: First-move link

    /// Start opens the link the first move came from: an email before a web page, whatever their order.
    private static func impulsFirstMoveLink(_ p: ImpulsProbe) async {
        let model = p.model
        let web = ContextLink(kind: .web, reference: "https://example.com/brief", displayName: "Brief").encodedLine
        let mail = ContextLink(kind: .email, reference: "message://%3Cprobe@example.com%3E", displayName: "Offer").encodedLine
        p.plant("First move link probe", notes: web + "\n" + mail, priority: .urgent)
        model.scope = .inbox
        model.didMutate()
        final class Box: @unchecked Sendable { var kind: ContextLink.Kind?; var count = 0 }
        let box = Box()
        let original = FocusStart.openLink
        FocusStart.openLink = { link, _ in box.kind = link.kind; box.count += 1 }
        defer { FocusStart.openLink = original }
        _ = await openImpuls(model)
        await returnUntil { box.kind != nil }
        record("Start opens the first move's link, an email before a web page, exactly once",
               box.kind == .email && box.count == 1, "kind=\(String(describing: box.kind)) count=\(box.count)")
    }

    // MARK: Undo pill primary action

    /// The shell mounts the pill from its state; Return runs a primary action raised with it.
    private static func undoPillPrimary(_ p: ImpulsProbe) async {
        let model = p.model
        p.plant("Pill probe", priority: .urgent, due: Day.today(calendar: KronosLocale.calendar))
        model.scope = .today
        model.didMutate()
        await settle(400)
        final class Flag: @unchecked Sendable { var started = false }
        let flag = Flag()
        UndoToastCenter.shared.show("Done. Next: probe", primaryTitle: "Start", onPrimary: { flag.started = true })
        let mounted = await waitUntil(timeout: 3) { UITestAnchors.frames["undo.pill"] != nil }
        // Return reaches the pill through the list: select a row first so the list holds the keyboard.
        _ = await click("row.Pill probe", xFraction: 0.45)
        await settle(300)
        await returnUntil { flag.started }
        record("the shell mounts the pill raised with a primary action and Return runs that action",
               mounted && flag.started, "mounted=\(mounted) started=\(flag.started)")
        UndoToastCenter.shared.dismiss()
    }

    // MARK: Now card actions

    private static func nowCardActions(_ p: ImpulsProbe, today: Int) async {
        let model = p.model, store = p.store
        let w = p.plant("Now card probe W", priority: .urgent, due: today)
        let x = p.plant("Now card probe X", priority: .high, due: today)
        model.scope = .today
        model.pinnedFocusTaskID = w.id
        model.didMutate()
        let shown = await waitUntil(timeout: 4) { UITestAnchors.frames["focus.start"] != nil }
        await settle(300)
        let sizes = ["focus.start", "focus.notnow", "focus.tomorrow"].compactMap { UITestAnchors.frames[$0] }
        let big = sizes.count == 3 && sizes.allSatisfy { $0.width >= Metrics.minHit && $0.height >= Metrics.minHit }
        record("Now card shows Start, Not now and Tomorrow, each at least 24 pt", shown && big,
               "shown=\(shown) frames=\(sizes.map { "\(Int($0.width))x\(Int($0.height))" })")

        // Not now on W: set aside for today, the pin moves to the other row.
        _ = await click("focus.notnow")
        await waitUntil(timeout: 3) { model.pinnedFocusTaskID == x.id }
        record("Not now on the Now card sets the task aside for today and moves on to the next row",
               ImpulsNotNow.isExcluded(w.id, today: today, in: KronosEnv.defaults) && model.pinnedFocusTaskID == x.id,
               "aside=\(ImpulsNotNow.isExcluded(w.id, today: today, in: KronosEnv.defaults)) pinnedX=\(model.pinnedFocusTaskID == x.id)")

        // Start on X: in progress and pinned, and the Start button is gone.
        await waitUntil(timeout: 3) { UITestAnchors.frames["focus.start"] != nil }
        _ = await click("focus.start")
        await waitUntil(timeout: 3) { store.task(x.id)?.status == .inProgress }
        let startGone = await waitUntil(timeout: 3) { UITestAnchors.frames["focus.start"] == nil }
        record("Start on the Now card puts the task in progress, pinned, and the button goes away",
               store.task(x.id)?.status == .inProgress && model.pinnedFocusTaskID == x.id && startGone,
               "status=\(String(describing: store.task(x.id)?.status)) startGone=\(startGone)")

        // Tomorrow on X: it leaves Today and the pin is cleared.
        _ = await click("focus.tomorrow")
        await waitUntil(timeout: 3) { store.task(x.id).map { !ScopeFilter.matches($0, scope: .today, today: today) } ?? false }
        let leftToday = store.task(x.id).map { !ScopeFilter.matches($0, scope: .today, today: today) } ?? false
        record("Tomorrow on the Now card takes the task out of Today and unpins it", leftToday && model.pinnedFocusTaskID != x.id,
               "leftToday=\(leftToday) pinnedStill=\(model.pinnedFocusTaskID == x.id)")
    }
}
#endif
