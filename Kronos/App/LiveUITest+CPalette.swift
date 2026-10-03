// Live steps for the command palette, driven through the real card with real keys: an exact title
// beyond the first eight results leads, every task row exists and writes the store (and raises the
// undo pill), the three second steps (date, rename, move) work from the keyboard, Complete hands the
// selection on, and the old names Impuls, Ordo and Triage still find their renamed commands.
// Run alone with `--only group:C-PALETTE`. Compiled only outside Release.
#if !RELEASE
import AppKit
import KronosCore

@MainActor
extension LiveUITest {
    static func cPaletteSteps(_ model: AppModel) async {
        await runStep(model) { await cpTopHit($0) }
        // The All list keeps a probe in view whatever its due date or status, so its selection survives.
        await runStep(model, scope: .all) { await cpTaskRows($0) }
        await runStep(model, scope: .all) { await cpPrompts($0) }
        await runStep(model) { await cpComplete($0) }
        await runStep(model) { await cpSynonyms($0) }
        await runStep(model) { await cpMorning($0) }
        await runStep(model, scope: .all) { await cpBreakdown($0) }
    }

    private static var cpBreak: Bool { ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil }

    // MARK: Helpers

    private static func cpOpen(_ model: AppModel) async -> Bool {
        // The list's new-task field can take the caret while the palette mounts (a busy run): typing
        // would then go to that field and Return would run nothing. Open again until the caret is in
        // the palette's own field.
        var shown = false
        for _ in 0..<3 {
            model.isPaletteOpen = true
            shown = await waitUntil(timeout: 3) { UITestAnchors.frames["palette.card"] != nil }
            await waitUntil(timeout: 2) { window.firstResponder is NSTextView }
            await settle(250)
            let inListField = (window.firstResponder as? NSTextView)?.accessibilityLabel() == String(localized: "list.new")
            if shown && !inListField { break }
            model.isPaletteOpen = false
            await settle(400)
        }
        return shown
    }

    private static func cpFlat(_ query: String, _ model: AppModel) -> [PaletteItem] {
        PaletteResults.groups(query: query, model: model).flatMap(\.items)
    }

    private static func cpCommandIndex(_ id: String, in flat: [PaletteItem]) -> Int? {
        flat.firstIndex { if case .command(let c) = $0 { return c.id == id }; return false }
    }

    private static func cpDown(_ times: Int) async {
        for _ in 0..<times { key("\u{F701}", modifiers: [.numericPad, .function], keyCode: 125); await settle(30) }
    }

    private static func cpReturn() { key("\r", keyCode: 36) }

    /// Opens the palette, types `typed`, moves the highlight to command `id` with ↓ and presses Return.
    /// False when the row is not offered for that text.
    private static func cpRun(_ id: String, typed: String, _ model: AppModel) async -> Bool {
        guard await cpOpen(model) else { return false }
        await typeText(typed)
        await settle(150)
        guard let index = cpCommandIndex(id, in: cpFlat(typed, model)) else { model.isPaletteOpen = false; return false }
        await cpDown(index)
        cpReturn()
        await settle(300)
        return true
    }

    private static func cpProbe(_ model: AppModel, _ title: String, notes: String = "", priority: KPriority = .none,
                                due: Int? = nil, status: KStatus = .todo) -> KTask {
        let t = model.store.createNoUndo(title: title, notes: notes, project: nil, status: status, priority: priority, dueDay: due)
        model.didMutate()
        return t
    }

    private static func cpSelect(_ model: AppModel, _ task: KTask) async {
        model.selectedTaskID = task.id
        model.didMutate()
        await settle(250)
    }

    private static func cpDiscard(_ model: AppModel, _ ids: [UUID]) {
        let now = Date()
        for id in ids { model.store.updateNoUndo(id) { $0.deletedAt = now } }
        model.selectedTaskID = nil
        model.didMutate()
    }

    private static func cpPillShown() -> Bool { UndoToastCenter.shared.current != nil }

    // MARK: Find a task

    /// Twelve tasks match "zqexact"; the exact title sorts last in the list order, past the eighth.
    private static func cpTopHit(_ model: AppModel) async {
        let today = Day.today()
        var ids: [UUID] = []
        for i in 1...10 {
            ids.append(cpProbe(model, "Fill zqexact note \(i)", priority: .urgent, due: today).id)
        }
        let exact = cpProbe(model, "zqexact")
        ids.append(exact.id)
        let byNotes = cpProbe(model, "Quiet thing", notes: "remember the zqnotes keyword")
        ids.append(byNotes.id)

        let flat = cpFlat("zqexact", model)
        var top: UUID?
        if case .task(let t)? = flat.first { top = t.id }
        record("palette: an exact title past the first eight results is the top hit",
               top == (cpBreak ? ids[0] : exact.id), "top=\(top?.uuidString ?? "nil") exact=\(exact.id)")

        let taskRows = flat.filter { if case .task = $0 { return true }; return false }.count
        record("palette: task results are capped at eight", taskRows == 8, "rows=\(taskRows)")

        let notesFlat = cpFlat("zqnotes", model)
        let foundByNotes = notesFlat.contains { if case .task(let t) = $0 { return t.id == byNotes.id }; return false }
        record("palette: a task is found by its notes", foundByNotes, "rows=\(notesFlat.count)")

        // The real keys: type it, Return opens the highlighted (top) task.
        var opened: UUID?
        if await cpOpen(model) {
            await typeText("zqexact")
            await settle(200)
            cpReturn()
            await waitUntil(timeout: 2) { model.selectedTaskID != nil }
            opened = model.selectedTaskID
        }
        record("palette: typing an exact title then Return opens that task", opened == exact.id,
               "opened=\(opened?.uuidString ?? "nil")")
        cpDiscard(model, ids)
    }

    // MARK: Task rows

    private static func cpTaskRows(_ model: AppModel) async {
        let store = model.store
        let today = Day.today()
        let task = cpProbe(model, "zqrow probe")
        await cpSelect(model, task)
        func fresh() -> KTask? { store.task(task.id) }

        // Dates: Tomorrow, Next week, Clear. One undo step and one pill each.
        var depth = store.undoDepth
        var ran = await cpRun("task.deadline.tomorrow", typed: "tomorrow", model)
        record("palette row Tomorrow sets the due date, one undo step, pill shown",
               ran && fresh()?.dueDay == today + 1 && store.undoDepth - depth == 1 && cpPillShown(),
               "ran=\(ran) due=\(String(describing: fresh()?.dueDay)) steps=\(store.undoDepth - depth)")
        ran = await cpRun("task.deadline.nextweek", typed: "next week", model)
        record("palette row Next week sets the due date", ran && fresh()?.dueDay == today + 7, "due=\(String(describing: fresh()?.dueDay))")
        depth = store.undoDepth
        ran = await cpRun("task.deadline.none", typed: "clear", model)
        record("palette row Clear removes the due date, one undo step",
               ran && fresh()?.dueDay == nil && store.undoDepth - depth == 1, "due=\(String(describing: fresh()?.dueDay))")

        // Status.
        ran = await cpRun("task.waiting", typed: "waiting", model)
        record("palette row Waiting moves the task to Waiting", ran && fresh()?.status == .waiting, "status=\(String(describing: fresh()?.status))")
        ran = await cpRun("task.someday", typed: "someday", model)
        record("palette row Someday moves the task to Someday", ran && fresh()?.status == .someday, "status=\(String(describing: fresh()?.status))")
        store.setStatus(task.id, .todo)
        model.didMutate()

        // Priority keeps writing and raising the pill.
        depth = store.undoDepth
        ran = await cpRun("task.priority.urgent", typed: "urgent", model)
        record("palette row Urgent sets the priority, one undo step, pill shown",
               ran && fresh()?.priority == .urgent && store.undoDepth - depth == 1 && cpPillShown(),
               "priority=\(String(describing: fresh()?.priority)) steps=\(store.undoDepth - depth)")

        // Duplicate: a second task with the same title, selected, one undo step.
        depth = store.undoDepth
        let before = store.allTasks().filter { $0.title == task.title }.count
        ran = await cpRun("task.duplicate", typed: "duplicate", model)
        let copies = store.allTasks().filter { $0.title == task.title }
        record("palette row Duplicate adds one copy, selects it, one undo step",
               ran && copies.count == before + 1 && model.selectedTaskID != task.id && store.undoDepth - depth == 1,
               "copies=\(copies.count) steps=\(store.undoDepth - depth)")
        let copyIDs = copies.map(\.id).filter { $0 != task.id }

        // Copy link: the pasteboard holds the task's kronos:// link and the store did not change.
        await cpSelect(model, task)
        NSPasteboard.general.clearContents()
        depth = store.undoDepth
        ran = await cpRun("task.copylink", typed: "copy kronos", model)
        let pasted = NSPasteboard.general.string(forType: .string)
        record("palette row Copy Kronos link puts the task link on the pasteboard, store unchanged",
               ran && pasted == TaskLink.string(for: task.id) && store.undoDepth == depth, "pasted=\(pasted ?? "nil")")

        cpDiscard(model, [task.id] + copyIDs)
    }

    // MARK: Second steps

    private static func cpPrompts(_ model: AppModel) async {
        let store = model.store
        let task = cpProbe(model, "zqprompt probe")
        let originalTitle = task.title   // `task` is the live row: its title changes with the rename
        await cpSelect(model, task)
        func fresh() -> KTask? { store.task(task.id) }

        // Pick a date: the hr phrase "za 3 dana" is three days out.
        var depth = store.undoDepth
        var ran = await cpRun("task.pickdate", typed: "pick", model)
        let promptShown = await waitUntil(timeout: 2) { UITestAnchors.frames["palette.prompt"] != nil }
        await waitUntil(timeout: 2) { window.firstResponder is NSTextView }
        await typeText("za 3 dana")
        await settle(200)
        cpReturn()
        await settle(300)
        record("palette Pick…: the date step opens, a typed phrase sets the date, one undo step",
               ran && promptShown && fresh()?.dueDay == Day.today() + 3 && store.undoDepth - depth == 1,
               "shown=\(promptShown) due=\(String(describing: fresh()?.dueDay)) steps=\(store.undoDepth - depth)")

        // Rename: the field starts with the current title; replacing it renames, one undo step.
        depth = store.undoDepth
        ran = await cpRun("task.rename", typed: "rename", model)
        let renameShown = await waitUntil(timeout: 2) { UITestAnchors.frames["palette.prompt"] != nil }
        await waitUntil(timeout: 2) { window.firstResponder is NSTextView }
        let prefilled = (window.firstResponder as? NSTextView)?.string
        (window.firstResponder as? NSTextView)?.selectAll(nil)
        await typeText("zqprompt renamed")
        await settle(200)
        cpReturn()
        await settle(300)
        record("palette Rename…: the field starts with the title, Return renames, one undo step",
               ran && renameShown && prefilled == originalTitle && fresh()?.title == "zqprompt renamed" && store.undoDepth - depth == 1,
               "prefilled=\(prefilled ?? "nil") title=\(fresh()?.title ?? "nil") steps=\(store.undoDepth - depth)")

        // Esc in the step goes back to the commands, not out of the palette.
        _ = await cpRun("task.rename", typed: "rename", model)
        await waitUntil(timeout: 2) { UITestAnchors.frames["palette.prompt"] != nil }
        key("\u{1B}", keyCode: 53)
        await settle(300)
        let backToCommands = UITestAnchors.frames["palette.card"] != nil && model.isPaletteOpen
        record("palette step: Esc returns to the command list and keeps the palette open", backToCommands,
               "open=\(model.isPaletteOpen)")
        model.isPaletteOpen = false

        // Move to…: type part of a project name, Return moves the task there.
        let project = store.createProject(name: "Zqmove Project")
        model.didMutate()
        depth = store.undoDepth
        ran = await cpRun("task.moveto", typed: "move to", model)
        let moveShown = await waitUntil(timeout: 2) { UITestAnchors.frames["palette.prompt"] != nil }
        await waitUntil(timeout: 2) { window.firstResponder is NSTextView }
        await typeText("zqmov")
        await settle(200)
        cpReturn()
        await settle(300)
        record("palette Move to…: the project step opens, a typed name moves the task, one undo step",
               ran && moveShown && fresh()?.projectID == project.id && store.undoDepth - depth == 1,
               "shown=\(moveShown) project=\(String(describing: fresh()?.projectID)) steps=\(store.undoDepth - depth)")
        store.archiveProject(project.id)
        cpDiscard(model, [task.id])
    }

    // MARK: Complete hands the selection on

    private static func cpComplete(_ model: AppModel) async {
        let store = model.store
        let today = Day.today()
        let a = cpProbe(model, "zqdone A", priority: .urgent, due: today)
        let b = cpProbe(model, "zqdone B", priority: .urgent, due: today)
        let c = cpProbe(model, "zqdone C", priority: .urgent, due: today)
        model.scope = .today
        await settle(300)
        await cpSelect(model, a)
        let depth = store.undoDepth
        let ran = await cpRun("task.complete", typed: "complete", model)
        await settle(300)
        let selected = model.selectedTaskID
        record("palette row Complete finishes the task and moves the selection to another row, pill shown",
               ran && store.task(a.id)?.status == .done && selected != nil && selected != a.id
                   && store.undoDepth - depth == 1 && cpPillShown(),
               "status=\(String(describing: store.task(a.id)?.status)) selected=\(selected?.uuidString ?? "nil") steps=\(store.undoDepth - depth)")
        cpDiscard(model, [a.id, b.id, c.id])
    }

    // MARK: Old names

    /// Typed word, command id, and what must have happened after Return.
    private static func cpSynonyms(_ model: AppModel) async {
        let box = CPBox()
        let token = NotificationCenter.default.addObserver(forName: .kronosShowOrdoRequested, object: nil, queue: .main) { _ in
            box.ordo = true
        }
        defer { NotificationCenter.default.removeObserver(token) }
        let cases: [(String, String, @MainActor () -> Bool)] = [
            ("impuls", "session.impuls", { model.isImpulsOpen }),
            ("triage", "session.triage", { model.isTriageOpen }),
            ("trijaža", "session.triage", { model.isTriageOpen }),
            ("pregled", "session.sweep", { model.isTriageOpen }),
            // Last: it opens the menu bar popover, which is closed again below.
            ("ordo", "session.upnext", { box.ordo }),
        ]
        for (word, id, effect) in cases {
            await resetState(model)
            box.ordo = false
            let offered = cpCommandIndex(id, in: cpFlat(word, model)) != nil
            let ran = await cpRun(id, typed: word, model)
            await waitUntil(timeout: 2) { effect() }
            let expected = cpBreak && word == "ordo" ? !effect() : effect()
            record("palette: typing \"\(word)\" finds the renamed command and Return runs it", offered && ran && expected,
                   "offered=\(offered) ran=\(ran) effect=\(effect())")
        }
        await cpCloseExtraWindows()
    }

    /// Closes whatever the last command opened beside the main window (the menu bar popover) and
    /// gives the main window the keyboard back.
    private static func cpCloseExtraWindows() async {
        for extra in NSApp.windows where extra !== window && extra.isVisible && (extra.level == .popUpMenu || extra.className.contains("Popover")) {
            extra.close()
        }
        await settle(200)
        window.makeKeyAndOrderFront(nil)
        await ensureKey(window)
    }

    // MARK: Morning plan, Break down

    private static func cpMorning(_ model: AppModel) async {
        let box = CPBox()
        let token = NotificationCenter.default.addObserver(forName: .kronosMorningPlanRequested, object: nil, queue: .main) { _ in
            box.morning = true
        }
        defer { NotificationCenter.default.removeObserver(token) }

        model.scope = .inbox
        let ran = await cpRun("session.morningplan", typed: "morning", model)
        await waitUntil(timeout: 2) { box.morning }
        record("palette row Morning plan posts the morning plan request and shows Today",
               ran && box.morning && model.scope == .today, "morning=\(box.morning) scope=\(model.scope)")
        // The request opened the real card: close it, or the next leaf starts with it on screen.
        if UITestAnchors.frames["morning.dismiss"] != nil { _ = await click("morning.dismiss") }
        await waitUntil(timeout: 2) { UITestAnchors.frames["morning.card"] == nil }
    }

    private static func cpBreakdown(_ model: AppModel) async {
        let task = cpProbe(model, "zqbreak probe")
        await cpSelect(model, task)
        let ranBreak = await cpRun("task.breakdown", typed: "break down", model)
        await waitUntil(timeout: 4) { UITestAnchors.frames["inspector.breakdown.preview"] != nil }
        let shown = UITestAnchors.frames["inspector.breakdown.preview"] != nil
        record("palette row Break down opens the task and shows its break-down preview",
               ranBreak && model.selectedTaskID == task.id && (cpBreak ? !shown : shown),
               "selected=\(model.selectedTaskID?.uuidString ?? "nil") preview=\(shown)")
        cpDiscard(model, [task.id])
    }
}

/// What notification observers saw. A class, so the main-queue observer closures can set it.
private final class CPBox: @unchecked Sendable {
    var ordo = false
    var morning = false
}
#endif
