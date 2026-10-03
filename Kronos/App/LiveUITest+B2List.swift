// Live steps for the list: the "Avoiding it" menu toggle, completion handing off to the next task
// (Space, then Return), "next" as the first eligible row of the shown list, the Today-clear state
// and its cue, and the child row's hit target. Run alone with `--only group:B2-LIST`.
#if !RELEASE
import AppKit
import KronosCore

@MainActor
extension LiveUITest {
    static func b2ListSteps(_ model: AppModel) async {
        await runStep(model) { await b2ListDreadToggle($0) }
        await runStep(model) { await b2ListDoneNext($0) }
        await runStep(model) { await b2ListPinWins($0) }
        await runStep(model) { await b2ListShownHead($0) }
        await runStep(model) { await b2ListChildHitTarget($0) }
        await runStep(model) { await b2ListTodayClear($0) }
        await runStep(model) { await b2ListEarlierFreshStart($0) }
    }

    // MARK: Earlier

    /// Five tasks four days late sit under a collapsed "Earlier (5)"; Tomorrow moves all five in
    /// one undo step; one Cmd-Z puts all five back under Earlier.
    private static func b2ListEarlierFreshStart(_ model: AppModel) async {
        let store = model.store
        let today = Day.today()
        ListEarlierState.shared.isExpanded = false
        // Park what Earlier already holds so the count is this step's own five.
        // The Today rows go too: a full run reaches here with enough of them that the Earlier header
        // sits below the window edge and its Tomorrow button cannot be clicked.
        let parkedContext = ListContext(model: model)
        let parked = parkedContext.earlier.map(\.id) + parkedContext.rows.map(\.id)
        let parkedAt = Date()
        for id in parked { store.updateNoUndo(id) { $0.deletedAt = parkedAt } }
        defer {
            for id in parked { store.updateNoUndo(id) { $0.deletedAt = nil } }
            model.didMutate()
        }
        let late = (1...5).map { i -> KTask in
            let t = store.createNoUndo(title: "Earlier probe \(i)", notes: "", project: nil, status: .todo, priority: .none, dueDay: today - 4)
            store.updateNoUndo(t.id) { $0.carryCount = 4; $0.originalDueDay = today - 4 }
            return t
        }
        let ids = Set(late.map(\.id))
        model.didMutate()
        // A full run reaches this step with Earlier already rendered (earlier steps leave late rows
        // there), so the anchor can be the previous layout's: let the list lay out first.
        await settle(400)
        await waitUntil { UITestAnchors.frames["today.earlier.tomorrow"] != nil }
        let ctx = ListContext(model: model)
        let underEarlier = Set(ctx.earlier.map(\.id)) == ids && ctx.rows.allSatisfy { !ids.contains($0.id) }
        let depth = store.undoDepth
        let clicked = await click("today.earlier.tomorrow")
        await waitUntil { late.allSatisfy { store.task($0.id)?.plannedDay == today + 1 } }
        let moved = late.allSatisfy { store.task($0.id)?.plannedDay == today + 1 }
        let oneStep = store.undoDepth - depth == 1
        let leftEarlier = ListContext(model: model).earlier.allSatisfy { !ids.contains($0.id) }

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nil)
        key("z", modifiers: .command, keyCode: 6)
        await waitUntil(timeout: 2) { late.allSatisfy { store.task($0.id)?.plannedDay == nil } }
        if !late.allSatisfy({ store.task($0.id)?.plannedDay == nil }) { _ = b2Undo() }
        await waitUntil { late.allSatisfy { store.task($0.id)?.plannedDay == nil } }
        model.didMutate()
        await settle(300)
        let back = Set(ListContext(model: model).earlier.map(\.id))
        let restored = b2Break ? back.isEmpty : back == ids
        record("Earlier (5) holds five late tasks; Tomorrow moves all five in one undo step; one Cmd-Z puts them back",
               underEarlier && clicked && moved && oneStep && leftEarlier && restored,
               "underEarlier=\(underEarlier) clicked=\(clicked) moved=\(moved) oneStep=\(oneStep) left=\(leftEarlier) restored=\(back.count)")
    }

    private static var b2Break: Bool { ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil }

    /// Undo through the Edit menu item (what ⌘Z runs), once.
    private static func b2Undo() -> Bool {
        guard let item = undoMenuItem(), let menu = item.menu else { return false }
        menu.performActionForItem(at: menu.index(of: item))
        return true
    }

    /// Probe rows placed above everything else in Manual order, due today, so they lead Today.
    private static func b2Probes(_ model: AppModel, _ titles: [String]) -> [KTask] {
        let store = model.store
        let today = Day.today()
        let floor = (store.allTasks().map(\.sortIndex).min() ?? 0) - Double(titles.count + 1) * 1024
        return titles.enumerated().map { i, title in
            let t = store.createNoUndo(title: title, notes: "", project: nil, status: .todo, priority: .none, dueDay: today)
            store.updateNoUndo(t.id) { $0.sortIndex = floor + Double(i) * 1024 }
            return t
        }
    }

    // MARK: Avoiding it

    /// The task menu's "Avoiding it" item turns the flag on, shows it checked, turns it off, and
    /// each change is one undo step. The parent cue goes to a parent with children only.
    private static func b2ListDreadToggle(_ model: AppModel) async {
        let store = model.store
        let t = store.create(title: "Avoid probe")
        model.didMutate()
        func nodes() -> [CtxNode] {
            TaskMenu.nodes(task: store.task(t.id)!, model: model, pickDue: {}, onSelect: {})
        }
        let present = CtxNodes.find(TaskMenu.dreadNodeID, in: nodes())
        let ranOn = CtxNodes.invoke(TaskMenu.dreadNodeID, in: nodes())
        await settle(150)
        let onNow = store.task(t.id)?.dread == true
        let shownChecked = CtxNodes.find(TaskMenu.dreadNodeID, in: nodes())?.checked == true
        let depth = store.undoDepth
        let ranOff = CtxNodes.invoke(TaskMenu.dreadNodeID, in: nodes())
        await settle(150)
        let offNow = store.task(t.id)?.dread == false
        let oneStep = store.undoDepth - depth == 1
        let undone = b2Undo()
        await settle(300)
        let restored = store.task(t.id)?.dread == !b2Break
        record("Avoiding it in the task menu turns on, shows checked, turns off, one undo step each",
               present?.checked == false && ranOn && onNow && shownChecked && ranOff && offNow && oneStep && undone && restored,
               "present=\(present != nil) on=\(onNow) checked=\(shownChecked) off=\(offNow) oneStep=\(oneStep) undo=\(undone) restored=\(restored)")

        let parent = store.create(title: "Parent cue probe")
        _ = store.addSubtaskNoUndo(parent.id, title: "Parent cue child")
        let single = store.create(title: "Single cue probe")
        let parentCue = ListCompletion.cue(forCompleted: parent.id, store: store)
        let singleCue = ListCompletion.cue(forCompleted: single.id, store: store)
        record("a parent with children earns the parent cue, a plain task the task cue",
               parentCue == .parent && singleCue == .task, "parent=\(parentCue) single=\(singleCue)")
    }

    // MARK: Done. Next

    /// Space on the selected row completes it; the row stays struck through for a moment; the
    /// pill reads "Done. Next: <first move>" naming the first ELIGIBLE row (a done row and a row
    /// pending review are skipped) and VoiceOver hears it; Return starts that task: in progress
    /// and pinned.
    private static func b2ListDoneNext(_ model: AppModel) async {
        let store = model.store
        var opts = model.options(for: .today)
        opts.showCompleted = true
        model.setOptions(opts, for: .today)
        let probes = b2Probes(model, ["Next probe current", "Next probe done", "Next probe review", "Next probe target"])
        let (current, done, review, target) = (probes[0], probes[1], probes[2], probes[3])
        store.completeNoUndo(done.id)
        store.updateNoUndo(review.id) { $0.reviewRaw = 1 }
        store.updateNoUndo(target.id) { $0.firstMove = "Open the probe folder" }
        model.searchText = "Next probe"
        model.didMutate()
        await waitUntil { UITestAnchors.frames["row." + current.title] != nil }

        let selected = await click("row." + current.title, xFraction: 0.45)
        await waitUntil { model.selectedTaskID == current.id }
        key(" ", keyCode: 49)
        await waitUntil { store.task(current.id)?.status == .done }
        let lingers = ListContext(model: model).rows.contains { $0.id == current.id }
        let pill = UndoToastCenter.shared.current
        let wantMessage = String(format: String(localized: "undo.donenext"), b2Break ? "Next probe review" : "Open the probe folder")
        let announced = ListPillAnnouncer.lastAnnouncement?.hasPrefix(wantMessage) == true
        record("Space completes; the pill reads Done. Next: with the first eligible row's move and is announced",
               selected && pill?.message == wantMessage && pill?.primaryTitle != nil && announced && lingers,
               "selected=\(selected) pill=\(pill?.message ?? "none") primary=\(pill?.primaryTitle ?? "none") announced=\(ListPillAnnouncer.lastAnnouncement ?? "none") lingers=\(lingers)")

        await ensureKey()
        key("\r", keyCode: 36)
        await waitUntil { store.task(target.id)?.status == .inProgress }
        let started = store.task(target.id)?.status == .inProgress
        record("Return on the Done. Next pill starts the next task: in progress and pinned",
               started && model.pinnedFocusTaskID == target.id && UndoToastCenter.shared.current == nil,
               "status=\(String(describing: store.task(target.id)?.status)) pinned=\(model.pinnedFocusTaskID == target.id)")
        model.pinnedFocusTaskID = nil
        model.setOptions(.default, for: .today)
    }

    /// A pinned open task wins over the first row: completing a row hands off to the pin.
    private static func b2ListPinWins(_ model: AppModel) async {
        let store = model.store
        let probes = b2Probes(model, ["Pin probe first", "Pin probe second"])
        let pinned = store.create(title: "Pin probe pinned elsewhere")
        store.updateNoUndo(pinned.id) { $0.firstMove = "Call the pinned probe" }
        model.pinnedFocusTaskID = pinned.id
        model.searchText = "Pin probe"
        model.didMutate()
        await waitUntil { UITestAnchors.frames["row." + probes[0].title] != nil }
        _ = await click("row." + probes[0].title, xFraction: 0.45)
        await waitUntil { model.selectedTaskID == probes[0].id }
        key(" ", keyCode: 49)
        await waitUntil { store.task(probes[0].id)?.status == .done }
        let want = String(format: String(localized: "undo.donenext"), b2Break ? "Pin probe second" : "Call the pinned probe")
        let got = UndoToastCenter.shared.current?.message
        record("the pin wins: completing a row hands off to the pinned task", got == want, "pill=\(got ?? "none")")
        UndoToastCenter.shared.dismiss()
        model.pinnedFocusTaskID = nil
    }

    // MARK: Shown list head

    /// "Next" follows the list being shown: on Today the head skips a done first row and the
    /// pin wins the focus; browsing Someday republishes the head as Someday's first eligible row.
    private static func b2ListShownHead(_ model: AppModel) async {
        let store = model.store
        var opts = model.options(for: .today)
        opts.showCompleted = true
        model.setOptions(opts, for: .today)
        let probes = b2Probes(model, ["Head probe done", "Head probe open"])
        store.completeNoUndo(probes[0].id)
        model.searchText = "Head probe"
        model.didMutate()
        await waitUntil { model.shownListHead.ids.first == probes[1].id }
        let todayHead = model.shownListHead
        let skipsDone = todayHead.ids.first == probes[1].id && !todayHead.ids.contains(probes[0].id)
        let focusIsOpen = model.ordoFocus.taskID == probes[1].id

        let pin = store.create(title: "Head probe pin")
        model.pinnedFocusTaskID = pin.id
        model.didMutate()
        await waitUntil { model.ordoFocus.taskID == pin.id }
        let pinWins = model.ordoFocus.taskID == pin.id && model.focusTaskID == pin.id
        model.pinnedFocusTaskID = nil

        let someday = store.createNoUndo(title: "Head probe someday", notes: "", project: nil, status: .someday, priority: .none, dueDay: nil)
        store.updateNoUndo(someday.id) { $0.sortIndex = (store.allTasks().map(\.sortIndex).min() ?? 0) - 1024 }
        model.setOptions(.default, for: .today)
        model.scope = .someday
        model.didMutate()
        await waitUntil { model.shownListHead.ids.first == someday.id }
        let somedayHead = model.shownListHead
        let browsing = somedayHead.ids.first == (b2Break ? probes[1].id : someday.id) && somedayHead.listName != todayHead.listName
        record("next is the first eligible row of the shown list: done skipped, pin wins, Someday when browsing Someday",
               skipsDone && focusIsOpen && pinWins && browsing,
               "today=\(todayHead.listName)/\(todayHead.ids.count) skipsDone=\(skipsDone) focus=\(focusIsOpen) pin=\(pinWins) someday=\(somedayHead.listName) first=\(somedayHead.ids.first == someday.id)")
    }

    // MARK: Child row

    /// The child's ⓘ button keeps a 24 x 24 pt target even while its glyph is hidden at rest.
    private static func b2ListChildHitTarget(_ model: AppModel) async {
        let store = model.store
        let parent = b2Probes(model, ["Child probe parent"])[0]
        guard let child = store.addSubtaskNoUndo(parent.id, title: "Child probe step") else {
            record("child probe created", false, "addSubtask returned nil"); return
        }
        model.searchText = "Child probe"
        model.didMutate()
        await waitUntil { UITestAnchors.frames["arrow." + parent.title] != nil }
        if UITestAnchors.frames["subrow." + child.title] == nil { _ = await click("arrow." + parent.title) }
        let anchor = "list.subtask.info.\(child.id.uuidString)"
        await waitUntil { UITestAnchors.frames[anchor] != nil }
        let f = UITestAnchors.frames[anchor] ?? .zero
        let floor = b2Break ? Metrics.minHit + 100 : Metrics.minHit
        record("child row info button hit target is at least 24 x 24 pt",
               f.width >= floor && f.height >= floor, "frame=\(Int(f.width))x\(Int(f.height))")
    }

    // MARK: Today is clear

    /// Finishing the last row of Today shows "Today is clear. N done." and plays the day-clear
    /// cue once; looking at the already empty Today again plays nothing.
    private static func b2ListTodayClear(_ model: AppModel) async {
        let store = model.store
        let today = Day.today()
        // Park everything Today shows (soft-delete without undo) and bring it back afterwards.
        let ctx0 = ListContext(model: model)
        let parked = (ctx0.rows + ctx0.earlier).map(\.id)
        let parkedAt = Date()
        for id in parked { store.updateNoUndo(id) { $0.deletedAt = parkedAt } }
        defer {
            for id in parked { store.updateNoUndo(id) { $0.deletedAt = nil } }
            model.didMutate()
        }
        model.didMutate()
        let probe = store.createNoUndo(title: "Clear probe last", notes: "", project: nil, status: .todo, priority: .none, dueDay: today)
        model.didMutate()
        await waitUntil { UITestAnchors.frames["row." + probe.title] != nil }
        let before = TodayClear.cuesPlayed
        _ = await click("row." + probe.title, xFraction: 0.45)
        await waitUntil { model.selectedTaskID == probe.id }
        key(" ", keyCode: 49)
        await waitUntil(timeout: 4) { TodayClear.cuesPlayed > before }
        let cue = TodayClear.cuesPlayed - before
        let shown = await waitUntil { UITestAnchors.frames["today.clear"] != nil }
        let done = TodayClear.doneToday(store)
        model.scope = .inbox
        await settle(300)
        model.scope = .today
        model.didMutate()
        await settle(600)
        let again = TodayClear.cuesPlayed - before
        record("finishing Today's last row shows Today is clear and plays the cue once; looking again is silent",
               cue == 1 && shown && done >= 1 && again == (b2Break ? 2 : 1),
               "cue=\(cue) shown=\(shown) done=\(done) afterRevisit=\(again)")
    }
}
#endif
