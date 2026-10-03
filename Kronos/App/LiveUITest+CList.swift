// Live steps for the list keyboard: the single-key grammar (T, ⇧T, H, S/M/L, W, Y, 0-4, D, P, B),
// a rebound key moving with its binding, the hold-⌥ legend, Return to the inspector title and Esc
// back, ⇧↓ range selection with one bulk step, the row menu's shape and its pill, one list build
// per mutation, Complete current from the background, empty states and drop hints. Every step
// uses real key events from the list (no direct calls) except Complete current, whose global
// hotkey cannot be pressed from inside the process. Run alone with `--only group:C-LIST`.
#if !RELEASE
import AppKit
import KronosCore

@MainActor
extension LiveUITest {
    static func cListSteps(_ model: AppModel) async {
        await runStep(model, scope: .all) { await cListGrammar($0) }
        await runStep(model, scope: .all) { await cListRebind($0) }
        await runStep(model, scope: .all) { await cListDateField($0) }
        await runStep(model, scope: .all) { await cListRangeAndBulk($0) }
        await runStep(model, scope: .all) { await cListLegend($0) }
        await runStep(model, scope: .all) { await cListMenu($0) }
        await runStep(model, scope: .all) { await cListOneBuild($0) }
        await runStep(model, scope: .all) { await cListReturnToTitle($0) }
        await runStep(model, scope: .all) { await cListBreakdown($0) }
        await runStep(model, scope: .all) { await cListProject($0) }
        await runStep(model, scope: .all) { await cListCompleteCurrent($0) }
        await runStep(model, scope: .all) { await cListEmptyAndHints($0) }
    }

    private static var cBreak: Bool { ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil }

    // MARK: Helpers

    /// Probe rows at the top of Manual order in All, with the search narrowing the list to them.
    private static func cProbes(_ model: AppModel, _ titles: [String]) async -> [KTask] {
        let store = model.store
        let floor = (store.allTasks().map(\.sortIndex).min() ?? 0) - Double(titles.count + 1) * 1024
        let tasks = titles.enumerated().map { i, title -> KTask in
            let t = store.createNoUndo(title: title, notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
            store.updateNoUndo(t.id) { $0.sortIndex = floor + Double(i) * 1024 }
            return t
        }
        model.setOptions(.default, for: .all)
        model.searchText = "Clist "
        model.didMutate()
        if let last = titles.last { await waitUntil(timeout: 4) { UITestAnchors.frames["row." + last] != nil } }
        await settle(300)
        return tasks
    }

    /// Clicks the row (the list takes the keyboard) and waits until it is the selection.
    @discardableResult
    private static func cSelect(_ model: AppModel, _ task: KTask) async -> Bool {
        model.selectedIDs = []
        if window.firstResponder is NSTextView { window.makeFirstResponder(nil) }
        let clicked = await click("row." + task.title, xFraction: 0.45)
        let ok = await waitUntil(timeout: 2) { model.selectedTaskID == task.id }
        await settle(150)
        return clicked && ok
    }

    private static func pillSays(_ text: String) -> Bool {
        UndoToastCenter.shared.current?.message.contains(text) == true
    }

    private static func undoOnce() -> Bool {
        guard let item = undoMenuItem(), let menu = item.menu else { return false }
        menu.performActionForItem(at: menu.index(of: item))
        return true
    }

    // MARK: Grammar

    private static func cListGrammar(_ model: AppModel) async {
        let store = model.store
        let today = Day.today()
        let p = await cProbes(model, ["Clist probe plan", "Clist probe effort", "Clist probe waiting",
                                      "Clist probe someday", "Clist probe priority", "Clist probe snooze"])

        // T: today, deadline untouched, one step, pill; ⇧T: tomorrow; one undo back.
        var sel = await cSelect(model, p[0])
        var depth = store.undoDepth
        key("t", keyCode: 17)
        await waitUntil { store.task(p[0].id)?.plannedDay == today }
        let tOK = store.task(p[0].id)?.plannedDay == (cBreak ? today + 1 : today) && store.task(p[0].id)?.dueDay == nil
            && store.undoDepth - depth == 1 && pillSays(p[0].title)
        record("list key T plans the task for today with the deadline untouched, one undo step, with the pill", sel && tOK,
               "selected=\(sel) planned=\(String(describing: store.task(p[0].id)?.plannedDay)) today=\(today) steps=\(store.undoDepth - depth) pill=\(UndoToastCenter.shared.current?.message ?? "nil")")
        sel = await cSelect(model, p[0])
        key("T", modifiers: .shift, keyCode: 17)
        await waitUntil { store.task(p[0].id)?.plannedDay == today + 1 }
        let shiftOK = store.task(p[0].id)?.plannedDay == today + 1
        _ = undoOnce(); await settle(300)
        record("list key shifted T plans tomorrow, one undo goes back to today", sel && shiftOK && store.task(p[0].id)?.plannedDay == today,
               "planned=\(String(describing: store.task(p[0].id)?.plannedDay))")

        // S / M / L effort.
        var efforts: [KEffort] = []
        for (ch, code) in [("s", UInt16(1)), ("m", UInt16(46)), ("l", UInt16(37))] {
            _ = await cSelect(model, p[1])
            key(ch, keyCode: code)
            await settle(250)
            efforts.append(store.task(p[1].id)?.effort ?? .none)
        }
        record("list keys S, M and L set small, medium and large effort, each with the pill",
               efforts == [.s, .m, .l] && pillSays(p[1].title), "efforts=\(efforts)")

        // W parks waiting (back in three days), W again releases.
        sel = await cSelect(model, p[2])
        key("w", keyCode: 13)
        await waitUntil { store.task(p[2].id)?.status == .waiting }
        let parked = store.task(p[2].id)?.status == .waiting && store.task(p[2].id)?.plannedDay == today + 3 && pillSays(p[2].title)
        _ = await cSelect(model, p[2])
        key("w", keyCode: 13)
        await waitUntil { store.task(p[2].id)?.status != .waiting }
        record("list key W parks the task as waiting until three days from now, W again releases it",
               sel && parked && store.task(p[2].id)?.status != .waiting,
               "status=\(String(describing: store.task(p[2].id)?.status)) planned=\(String(describing: store.task(p[2].id)?.plannedDay))")

        // Y someday, Y again back.
        sel = await cSelect(model, p[3])
        key("y", keyCode: 16)
        await waitUntil { store.task(p[3].id)?.status == .someday }
        let someday = store.task(p[3].id)?.status == .someday && pillSays(p[3].title)
        _ = await cSelect(model, p[3])
        key("y", keyCode: 16)
        await waitUntil { store.task(p[3].id)?.status == .todo }
        record("list key Y moves the task to Someday and back", sel && someday && store.task(p[3].id)?.status == .todo,
               "status=\(String(describing: store.task(p[3].id)?.status))")

        // 0-4 priority.
        sel = await cSelect(model, p[4])
        key("3", keyCode: 20)
        await waitUntil { store.task(p[4].id)?.priority == .high }
        let high = store.task(p[4].id)?.priority == .high && pillSays(p[4].title)
        _ = await cSelect(model, p[4])
        key("0", keyCode: 29)
        await waitUntil { store.task(p[4].id)?.priority == KPriority.none }
        record("list keys 3 and 0 set and clear priority", sel && high && store.task(p[4].id)?.priority == KPriority.none,
               "priority=\(String(describing: store.task(p[4].id)?.priority))")

        // H snoozes (plans tomorrow).
        sel = await cSelect(model, p[5])
        depth = store.undoDepth
        key("h", keyCode: 4)
        await waitUntil { store.task(p[5].id)?.plannedDay == today + 1 }
        record("list key H snoozes to tomorrow with one undo step", sel && store.task(p[5].id)?.plannedDay == today + 1
               && store.undoDepth - depth == 1, "planned=\(String(describing: store.task(p[5].id)?.plannedDay))")
    }

    /// A rebound grammar key moves with its binding and the old letter goes dead.
    private static func cListRebind(_ model: AppModel) async {
        let store = model.store
        let today = Day.today()
        let p = await cProbes(model, ["Clist probe rebind"])
        HotkeyRegistry.setOverride(HotkeyBinding("j"), for: "list.snooze")
        defer { HotkeyRegistry.setOverride(nil, for: "list.snooze") }
        await settle(300)
        let sel = await cSelect(model, p[0])
        key("h", keyCode: 4)
        await settle(400)
        let oldDead = store.task(p[0].id)?.plannedDay == nil
        _ = await cSelect(model, p[0])
        key("j", keyCode: 38)
        await waitUntil { store.task(p[0].id)?.plannedDay == today + 1 }
        record("snooze rebound to J: J snoozes, H does nothing", sel && oldDead && store.task(p[0].id)?.plannedDay == today + 1,
               "oldDead=\(oldDead) planned=\(String(describing: store.task(p[0].id)?.plannedDay))")
    }

    // MARK: D: the typed date field

    private static func cListDateField(_ model: AppModel) async {
        let store = model.store
        let today = Day.today()
        let p = await cProbes(model, ["Clist probe date"])
        let main = window!
        let sel = await cSelect(model, p[0])
        key("d", keyCode: 2)
        let opened = await waitUntil(timeout: 3) { UITestAnchors.frames["list.due.field"] != nil }
        // The popover holds the keyboard: type into its own window.
        await waitUntil(timeout: 2) { NSApp.keyWindow != nil && NSApp.keyWindow !== main }
        if let pop = NSApp.keyWindow, pop !== main { window = pop }
        await typeText("tomorrow")
        key("\r", keyCode: 36)
        await waitUntil { store.task(p[0].id)?.dueDay == today + 1 }
        window = main
        await ensureKey(main)
        // The field is closed when its popover window is gone; the anchor of a closed popover can stay
        // in the table (it did on the host lane), so the window decides.
        let closed = await waitUntil(timeout: 2) {
            UITestAnchors.frames["list.due.field"] == nil || !NSApp.windows.contains { $0.isVisible && $0 !== main }
        }
        record("list key D opens the date field; typing tomorrow and Return sets the deadline, closes the field, with the pill",
               sel && opened && store.task(p[0].id)?.dueDay == today + 1 && closed && pillSays(p[0].title),
               "opened=\(opened) due=\(String(describing: store.task(p[0].id)?.dueDay)) closed=\(closed) pill=\(UndoToastCenter.shared.current?.message ?? "nil")")
    }

    // MARK: ⇧↓ range and one bulk step

    private static func cListRangeAndBulk(_ model: AppModel) async {
        let store = model.store
        let today = Day.today()
        let p = await cProbes(model, ["Clist probe range a", "Clist probe range b", "Clist probe range c", "Clist probe range d"])
        let sel = await cSelect(model, p[0])
        let down = String(UnicodeScalar(0xF701)!)
        key(down, modifiers: [.shift, .numericPad, .function], keyCode: 125)
        await settle(200)
        key(down, modifiers: [.shift, .numericPad, .function], keyCode: 125)
        await waitUntil { model.selectedIDs.count == 3 }
        let three = Set(p[0...2].map(\.id))
        let rangeOK = model.selectedIDs == three && model.selectedTaskID == p[0].id
        let barShown = await waitUntil(timeout: 2) { UITestAnchors.frames["bulk.date"] != nil && UITestAnchors.frames["bulk.status"] != nil }
        record("shift-down twice selects three rows from the anchor and shows the bulk bar with Date and Status",
               sel && rangeOK && barShown, "selected=\(model.selectedIDs.count) anchor=\(model.selectedTaskID == p[0].id) bar=\(barShown)")
        let depth = store.undoDepth
        key("t", keyCode: 17)
        await waitUntil { p[0...2].allSatisfy { store.task($0.id)?.plannedDay == today } }
        let all = p[0...2].allSatisfy { store.task($0.id)?.plannedDay == today } && store.task(p[3].id)?.plannedDay == nil
        record("T on three selected rows plans all three for today as one undo step with one pill",
               all && store.undoDepth - depth == 1 && UndoToastCenter.shared.current != nil,
               "steps=\(store.undoDepth - depth) pill=\(UndoToastCenter.shared.current?.message ?? "nil")")
        model.selectedIDs = []
    }

    // MARK: ⌥ legend

    private static func cListLegend(_ model: AppModel) async {
        let p = await cProbes(model, ["Clist probe legend"])
        let sel = await cSelect(model, p[0])
        flags(.option)
        let shown = await waitUntil(timeout: 2) { UITestAnchors.frames["list.legend"] != nil }
        flags([])
        let gone = await waitUntil(timeout: 2) { UITestAnchors.frames["list.legend"] == nil }
        // A quick ⌥ tap shows nothing.
        flags(.option); await settle(100); flags([])
        await settle(500)
        let tapQuiet = UITestAnchors.frames["list.legend"] == nil
        record("holding Option shows the key legend over the list, letting go hides it, a quick tap shows nothing",
               sel && shown && gone && tapQuiet, "shown=\(shown) gone=\(gone) tapQuiet=\(tapQuiet)")
    }

    /// A modifier change event (⌥ down / up) delivered like the keyboard does.
    private static func flags(_ mods: NSEvent.ModifierFlags) {
        if let e = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: mods,
                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                    context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58) {
            NSApp.postEvent(e, atStart: false)
        }
    }

    // MARK: Row menu

    private static func cListMenu(_ model: AppModel) async {
        let store = model.store
        let p = await cProbes(model, ["Clist probe menu"])
        _ = await cSelect(model, p[0])
        guard let nodes = CtxMenuRegistry.nodes("row.\(p[0].id.uuidString)") else {
            record("the task row carries its menu", false, "registered=\(CtxMenuRegistry.ids.prefix(8))"); return
        }
        let shown = CtxNodes.visible(nodes)
        let dueKids: [String] = {
            guard let due = CtxNodes.find("due", in: shown), case .submenu(let kids) = due.kind else { return [] }
            return kids.map(\.id)
        }()
        let shapeOK = CtxNodes.depth(shown) <= 1 && !CtxNodes.containsDisabled(shown)
            && shown.last?.id == "delete" && shown.contains { $0.id == "dread" }
            && dueKids == ["due.today", "due.tomorrow", "due.nextweek", "due.pick"]
        record("the row menu shows no disabled item, one submenu level, Clear hidden on an undated task, Delete last",
               shapeOK, "depth=\(CtxNodes.depth(shown)) top=\(shown.map(\.id)) due=\(dueKids)")
        let depth = store.undoDepth
        let ran = CtxNodes.invoke("priority.\(KPriority.high.rawValue)", in: CtxMenuRegistry.nodes("row.\(p[0].id.uuidString)") ?? [])
        await settle(200)
        record("a priority change from the row menu is one undo step and raises the pill",
               ran && store.task(p[0].id)?.priority == .high && store.undoDepth - depth == 1 && pillSays(p[0].title),
               "ran=\(ran) steps=\(store.undoDepth - depth) pill=\(UndoToastCenter.shared.current?.message ?? "nil")")
    }

    // MARK: One build per mutation

    private static func cListOneBuild(_ model: AppModel) async {
        let store = model.store
        let p = await cProbes(model, ["Clist probe build"])
        _ = await cSelect(model, p[0])
        await settle(700)
        let before = ListContext.builds
        key("2", keyCode: 19)
        await waitUntil { store.task(p[0].id)?.priority == .medium }
        await settle(900)
        let builds = ListContext.builds - before
        record("one priority key press builds the list snapshot once", builds == 1, "builds=\(builds)")
    }

    // MARK: Return to the inspector

    /// Return opens the selected row in the inspector and asks for its title field
    /// (`kronosFocusInspectorTitleRequested` with the task id). Putting the caret there and saving
    /// on Esc is the inspector's side of the contract (not this list's).
    private static func cListReturnToTitle(_ model: AppModel) async {
        await setWindowSize(width: 1500, height: 820)
        let p = await cProbes(model, ["Clist probe title"])
        final class Box: @unchecked Sendable { var ids: [UUID] = [] }
        let box = Box()
        let token = NotificationCenter.default.addObserver(forName: UIRequests.focusInspectorTitle, object: nil, queue: .main) { n in
            if let id = n.userInfo?["taskID"] as? UUID { box.ids.append(id) }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        let sel = await cSelect(model, p[0])
        key("\r", keyCode: 36)
        let asked = await waitUntil(timeout: 2) { box.ids.contains(p[0].id) }
        let shown = model.inspectedTaskID == p[0].id
        record("Return opens the selected row in the inspector and asks for its title field",
               sel && asked && shown, "asked=\(box.ids.count) shown=\(shown)")
        if window.firstResponder is NSTextView { window.makeFirstResponder(nil) }
    }

    // MARK: B: Break down preview

    private static func cListBreakdown(_ model: AppModel) async {
        let store = model.store
        await setWindowSize(width: 1500, height: 820)
        let p = await cProbes(model, ["Clist probe plan the team offsite"])
        let sel = await cSelect(model, p[0])
        key("b", keyCode: 11)
        let preview = await waitUntil(timeout: 3) { UITestAnchors.frames["inspector.breakdown.preview"] != nil }
        key("\r", modifiers: .command, keyCode: 36)
        let added = await waitUntil(timeout: 3) { (store.task(p[0].id)?.orderedSubtasks.count ?? 0) >= 3 }
        record("list key B opens the Break down preview at once and Command-Return adds the steps",
               sel && preview && added, "preview=\(preview) steps=\(store.task(p[0].id)?.orderedSubtasks.count ?? -1)")
    }

    // MARK: P: project picker

    private static func cListProject(_ model: AppModel) async {
        let store = model.store
        let p = await cProbes(model, ["Clist probe project"])
        guard let target = store.allProjects().first(where: { $0.name.hasPrefix("Globex") }) else {
            record("list key P: a Globex project exists in the demo data", false, "projects=\(store.allProjects().map(\.name))"); return
        }
        let main = window!
        let sel = await cSelect(model, p[0])
        key("p", keyCode: 35)
        let opened = await waitUntil(timeout: 3) { UITestAnchors.frames["list.project.picker"] != nil }
        await waitUntil(timeout: 2) { NSApp.keyWindow != nil && NSApp.keyWindow !== main }
        if let pop = NSApp.keyWindow, pop !== main { window = pop }
        await typeText("glob")
        await settle(200)
        key("\r", keyCode: 36)
        await waitUntil { store.task(p[0].id)?.projectID == target.id }
        window = main
        await ensureKey(main)
        record("list key P, typing part of a project name and Return moves the task there, with the pill",
               sel && opened && store.task(p[0].id)?.projectID == target.id && pillSays(target.name),
               "opened=\(opened) project=\(store.task(p[0].id)?.project?.name ?? "nil")")
    }

    // MARK: Complete current (global ⌃⌥⏎)

    private static func cListCompleteCurrent(_ model: AppModel) async {
        let store = model.store
        let p = await cProbes(model, ["Clist probe current"])
        model.pinnedFocusTaskID = p[0].id
        final class Counter: @unchecked Sendable { var n = 0 }
        let completions = Counter()
        let token = NotificationCenter.default.addObserver(forName: .kronosTaskDidComplete, object: nil, queue: .main) { _ in
            completions.n += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }
        // The registry chord is a real global shortcut (the KeyboardShortcuts name itself is never
        // touched here: creating it would register the hotkey and write the shared defaults).
        let registered = HotkeyRegistry.current(for: "global.completecurrent")?.globalShortcut != nil
        // From another app: Kronos is hidden while the key acts.
        NSApp.hide(nil)
        await settle(400)
        let ran = GlobalTaskHotkeys.completeCurrent(model: model)
        await waitUntil { store.task(p[0].id)?.status == .done }
        let done = store.task(p[0].id)?.status == .done
        let pill = pillSays(p[0].title) || UndoToastCenter.shared.current?.primaryTitle != nil
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        await ensureKey(window)
        record("Complete current from the background completes the pinned task with the completion signal and the pill",
               registered && ran && done && completions.n >= 1 && pill,
               "registered=\(registered) ran=\(ran) done=\(done) signals=\(completions.n) pill=\(UndoToastCenter.shared.current?.message ?? "nil")")
    }

    // MARK: Empty state, drop hints

    private static func cListEmptyAndHints(_ model: AppModel) async {
        let store = model.store
        let project = store.createProject(name: "Clist empty project", colorHex: "#5B8DEF", icon: "folder", area: nil)
        model.scope = .project(project.id)
        model.didMutate()
        let shown = await waitUntil(timeout: 3) { UITestAnchors.frames["list.empty"] != nil && UITestAnchors.frames["empty.action"] != nil }
        let clicked = await click("empty.action")
        let fieldFocused = await waitUntil(timeout: 2) { window.firstResponder is NSTextView }
        if window.firstResponder is NSTextView { window.makeFirstResponder(nil) }
        record("an empty project says what it is for and its New task action focuses the new-task row",
               shown && clicked && fieldFocused, "shown=\(shown) clicked=\(clicked) focused=\(fieldFocused)")
        let chord = (HotkeyRegistry.current(for: "window.nest")?.displayKeys ?? []).joined()
        let nest = DropHintText.text(for: .nest)
        let promote = DropHintText.text(for: .promote)
        let promoteChord = (HotkeyRegistry.current(for: "window.unnest")?.displayKeys ?? []).joined()
        record("the nest and promote drag hints name the key that does the same", !chord.isEmpty && nest.contains(chord)
               && promote.contains(promoteChord) && !nest.contains("%"), "nest=\(nest) promote=\(promote)")
    }
}
#endif
