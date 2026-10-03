// Kronos/App/LiveUITest+Nesting.swift
// Live steps for Cmd-] / Cmd-[ and for a parent task shown in Today because of a subtask.
//   A. Cmd-] makes the selected task a subtask of the row above it (one undo step), on the US key
//      codes and on the Croatian ones (the same physical keys print dj / s-caron there).
//   B. First row: a notice pill says why, nothing changes, no undo step. A recurring task nests
//      like any other (a subtask is a full task and keeps its rule), one undo step.
//   C. Cmd-[ promotes the focused subtask (middle list row, then inspector step) to a task right
//      after its parent; with no subtask focused it only says so.
//   D. While a text field is editing neither chord does anything.
//   E. Today shows the PARENT of a due subtask once (never the subtask as a row), the subtask is
//      marked inside the expanded parent, and completing it takes the parent out of Today.
// Judged on model state. The menu item is the fallback when a synthetic chord never reaches the
// menu (recorded as informational), exactly like the Shift-Cmd-N step.
#if !RELEASE
import AppKit
import KronosCore

@MainActor
extension LiveUITest {


    /// The Task-menu item for a bracket key (Cmd only).
    private static func bracketItem(_ key: String) -> NSMenuItem? {
        func find(_ menu: NSMenu?) -> NSMenuItem? {
            for item in menu?.items ?? [] {
                // SwiftUI renders the shortcut with the active layout's character: on a Croatian
                // layout the bracket keys are Dj and S-caron.
                if [key, key == "]" ? "đ" : "š"].contains(item.keyEquivalent),
                   item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == .command { return item }
                if let hit = find(item.submenu) { return hit }
            }
            return nil
        }
        return find(NSApp.mainMenu)
    }

    /// Sends the chord as a real key event; when `changed` is still false afterwards, runs the menu
    /// item instead. Returns whether the key event itself did the work.
    private static func chord(_ chars: String, keyCode: UInt16, item: String, changed: () -> Bool) async -> Bool {
        key(chars, modifiers: .command, keyCode: keyCode)
        await settle(500)
        if changed() { return true }
        if let menuItem = bracketItem(item), let menu = menuItem.menu { menu.performActionForItem(at: menu.index(of: menuItem)) }
        await settle(500)
        return false
    }

    private static func runMenuItem(_ key: String) async {
        if let item = bracketItem(key), let menu = item.menu { menu.performActionForItem(at: menu.index(of: item)) }
        await settle(500)
    }

    private static func performUndo() async {
        if let item = undoMenuItem(), let menu = item.menu { menu.performActionForItem(at: menu.index(of: item)) }
        await settle(500)
    }

    private static func manualTitles(_ store: TaskStore) -> [String] {
        KTaskSorter.sorted(store.allTasks().filter { $0.title.hasPrefix("L5X") }, by: [.asc(.manual)]).map(\.title)
    }

    static func nestingStep(_ model: AppModel) async {
        let breakMode = ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil
        let store = model.store
        guard bracketItem("]") != nil, bracketItem("[") != nil else {
            var seen: [String] = []
            func walk(_ m: NSMenu?, _ top: String) { for i in m?.items ?? [] { if top == "Task" { seen.append("\(i.title)|\(i.keyEquivalent)|\(i.keyEquivalentModifierMask.rawValue)") }; walk(i.submenu, top.isEmpty ? i.title : top) } }
            walk(NSApp.mainMenu, "")
            record("nesting: the Task menu has Cmd-] and Cmd-[", false, "missing items; Task menu=\(seen) tops=\((NSApp.mainMenu?.items ?? []).map(\.title))"); return
        }
        record("nesting: the Task menu has Cmd-] and Cmd-[", true, "")

        var frame = window.frame
        frame.size = NSSize(width: max(frame.width, 1500), height: max(frame.height, 800))
        window.setFrame(frame, display: true)
        model.scope = .all
        model.searchText = "L5X"
        let alpha = store.create(title: "L5X alpha")
        let bravo = store.create(title: "L5X bravo", priority: .high, dueDay: Day.today() + 3)
        let charlie = store.create(title: "L5X charlie")
        model.didMutate()
        await settle(700)

        // A. Cmd-] with the US key code.
        var ok = await click("row." + bravo.title, xFraction: 0.45)
        await settle(300)
        let selected = ok && model.selectedTaskID == bravo.id
        let depth0 = store.undoDepth
        let delivered = await chord("]", keyCode: 30, item: "]") { store.task(bravo.id)?.parentID == alpha.id }
        let nested = store.task(alpha.id)?.orderedSubtasks.map(\.title) ?? []
        let expectedParent = breakMode ? bravo.id : alpha.id
        record("nest: Cmd-] makes the selected task a subtask of the row above, selection moves to the parent",
               selected && nested == ["L5X bravo"] && model.selectedTaskID == expectedParent && store.task(bravo.id)?.parentID == alpha.id,
               "selected=\(selected) subtasks=\(nested) selection=\(String(describing: model.selectedTaskID)) alpha=\(alpha.id)")
        record("nest: the step keeps its due day and priority, and the chord is ONE undo step",
               store.task(alpha.id)?.orderedSubtasks.first?.dueDay == Day.today() + 3
                   && store.task(alpha.id)?.orderedSubtasks.first?.priority == .high && store.undoDepth == depth0 + 1,
               "undoStepsAdded=\(store.undoDepth - depth0)")
        record("nest: (informational) the real Cmd-] key event reached the app", true, "delivered=\(delivered)")
        let pill = UndoToastCenter.shared.current
        record("nest: the undo pill names both tasks", pill?.isNotice == false && (pill?.message.contains("L5X alpha") ?? false) && (pill?.message.contains("L5X bravo") ?? false),
               "message=\(pill?.message ?? "nil")")

        await performUndo()
        record("nest: one Undo brings the task back with the same id and removes the step",
               store.task(bravo.id) != nil && (store.task(alpha.id)?.orderedChildren ?? []).isEmpty,
               "bravoBack=\(store.task(bravo.id) != nil) steps=\(store.task(alpha.id)?.orderedSubtasks.count ?? -1)")

        // A2. Same chord, Croatian key codes (dj = keycode 30, s-caron = keycode 33).
        await settle(400)
        _ = await click("row." + bravo.title, xFraction: 0.45)
        await settle(300)
        let deliveredHR = await chord("\u{111}", keyCode: 30, item: "]") { store.task(bravo.id)?.parentID == alpha.id }
        record("nest: Cmd-Dj (Croatian layout, same physical key) nests too",
               store.task(alpha.id)?.orderedSubtasks.map(\.title) == ["L5X bravo"], "deliveredByKey=\(deliveredHR)")

        // C. Cmd-[ on a focused subtask row in the middle list: expand, click the step, press.
        await settle(300)
        _ = await click("row." + alpha.title, xFraction: 0.45)
        await settle(300)
        if UITestAnchors.frames["subrow." + bravo.title] == nil { _ = await click("arrow." + alpha.title); await settle(500) }
        ok = await click("subrow." + bravo.title, xFraction: 0.6)
        await settle(400)
        let stepID = store.task(alpha.id)?.orderedSubtasks.first?.id
        record("promote: clicking a subtask row focuses it and keeps its parent selected",
               ok && stepID != nil && SubtaskFocus.current(in: model) == stepID && model.selectedTaskID == alpha.id,
               "found=\(ok) focused=\(String(describing: SubtaskFocus.current(in: model))) step=\(String(describing: stepID))")
        let depth1 = store.undoDepth
        let deliveredUnnest = await chord("[", keyCode: 33, item: "[") { (store.task(alpha.id)?.orderedChildren ?? []).isEmpty }
        let order = manualTitles(store)
        let promoted = store.allTasks().first { $0.title == "L5X bravo" }
        record("promote: Cmd-[ turns the focused subtask into a task directly after its parent, due and priority kept",
               promoted != nil && order == ["L5X alpha", "L5X bravo", "L5X charlie"]
                   && promoted?.dueDay == Day.today() + 3 && promoted?.priority == .high && model.selectedTaskID == promoted?.id,
               "order=\(order) selection=\(String(describing: model.selectedTaskID))")
        record("promote: one undo step", store.undoDepth == depth1 + 1, "undoStepsAdded=\(store.undoDepth - depth1)")
        record("promote: (informational) the real Cmd-[ key event reached the app", true, "delivered=\(deliveredUnnest)")

        // C2. Cmd-[ with a task (not a subtask) selected: a notice, nothing changes.
        _ = await click("row." + charlie.title, xFraction: 0.45)
        await settle(300)
        let before = manualTitles(store)
        let depth2 = store.undoDepth
        await runMenuItem("[")
        let notice = UndoToastCenter.shared.current
        record("promote: with no subtask focused, Cmd-[ only says so",
               notice?.isNotice == true && notice?.message == "Click a subtask first." && manualTitles(store) == before && store.undoDepth == depth2,
               "message=\(notice?.message ?? "nil") undoStepsAdded=\(store.undoDepth - depth2)")

        // B. Refusals.
        await settle(300)
        _ = await click("row." + alpha.title, xFraction: 0.45)
        await settle(300)
        let depth3 = store.undoDepth
        await runMenuItem("]")
        let first = UndoToastCenter.shared.current
        record("nest: the first row has nothing above: notice, nothing changes",
               first?.isNotice == true && first?.message == "There is no task above to nest under."
                   && store.task(alpha.id) != nil && store.undoDepth == depth3,
               "message=\(first?.message ?? "nil")")

        let rec = store.create(title: "L5X recurring")
        rec.recurrenceRule = "FREQ=WEEKLY"
        model.didMutate()
        await settle(600)
        _ = await click("row." + rec.title, xFraction: 0.45)
        await settle(300)
        let depth4 = store.undoDepth
        let above = KeyboardNesting.taskAbove(rec.id, in: ListContext(model: model).rows.map(\.id))
        await runMenuItem("]")
        let nestedRec = store.task(rec.id)
        record("nest: a recurring task nests under the row above and keeps its rule, one undo step",
               nestedRec?.parentID != nil && nestedRec?.parentID == above && nestedRec?.recurrenceRule == "FREQ=WEEKLY"
                   && store.undoDepth == depth4 + 1,
               "parent=\(String(describing: nestedRec?.parentID)) above=\(String(describing: above)) rule=\(nestedRec?.recurrenceRule ?? "nil") steps=\(store.undoDepth - depth4)")
        store.undo(); model.didMutate()
        await settle(400)

        // D. While a text field is editing, the chord is not ours.
        _ = await click("row." + charlie.title, xFraction: 0.45)
        await settle(300)
        NotificationCenter.default.post(name: Notification.Name("kronosFocusSearchRequested"), object: nil)
        await settle(500)
        let typing = TaskListScreen.isTyping
        let depth5 = store.undoDepth
        await runMenuItem("]")
        record("nest: with a text field editing, Cmd-] does nothing",
               typing && store.task(charlie.id) != nil && store.undoDepth == depth5,
               "typing=\(typing) charlieStillTask=\(store.task(charlie.id) != nil)")
        NotificationCenter.default.post(name: Notification.Name("kronosFocusListRequested"), object: nil)
        await settle(300)
        // Posting the request moves SwiftUI focus; the search field's AppKit editor can stay first responder.
        if TaskListScreen.isTyping { window.makeFirstResponder(nil); await settle(300) }

        // C3. Cmd-[ on a focused INSPECTOR step.
        if let promotedBravo = store.allTasks().first(where: { $0.title == "L5X bravo" }) {
            try? store.makeTaskSubtaskOf(promotedBravo.id, parentID: alpha.id)
            model.didMutate()
            // An inline notice from the previous step can still be fading out and shifts the rows by a
            // line: wait for the layout to rest, and retry the click if it did not land on the row.
            var alphaClicked = false
            for _ in 0..<3 {
                await settle(900)
                if TaskListScreen.isTyping { window.makeFirstResponder(nil) }
                alphaClicked = await click("row." + alpha.title, xFraction: 0.45)
                await settle(600)
                if model.selectedTaskID == alpha.id { break }
            }
            let found = await click("step." + bravo.title, xFraction: 0.6)
            await settle(400)
            let inspectorStep = store.task(alpha.id)?.orderedSubtasks.first?.id
            let focusedHere = SubtaskFocus.current(in: model) == inspectorStep
            _ = await chord("[", keyCode: 33, item: "[") { (store.task(alpha.id)?.orderedChildren ?? []).isEmpty }
            record("promote: Cmd-[ on a focused inspector step promotes it too",
                   alphaClicked && found && focusedHere && (store.task(alpha.id)?.orderedChildren ?? []).isEmpty && store.allTasks().contains { $0.title == "L5X bravo" },
                   "found=\(found) focused=\(focusedHere) order=\(manualTitles(store))")
        }

        await todayParentStep(model)
        model.searchText = ""
    }

    // MARK: E. Today

    private static func todayParentStep(_ model: AppModel) async {
        let store = model.store
        let today = Day.today()
        model.scope = .today
        model.searchText = "L5T"
        let parent = store.create(title: "L5T parent")                               // no own day
        let step = store.addSubtaskNoUndo(parent.id, title: "L5T due step", dueDay: today, priority: .none)
        let quiet = store.create(title: "L5T quiet parent", dueDay: today + 9)
        _ = store.addSubtask(quiet.id, title: "L5T later step")
        let plain = store.create(title: "L5T plain future", dueDay: today + 5)
        _ = plain
        model.didMutate()
        await settle(800)

        record("today: a parent whose undone subtask is due today is a row",
               UITestAnchors.frames["row." + parent.title] != nil, "row=\(UITestAnchors.frames["row." + parent.title] != nil)")
        record("today: the subtask is not a row of its own, and parents with only later dates stay out",
               UITestAnchors.frames["row." + "L5T due step"] == nil && UITestAnchors.frames["row." + quiet.title] == nil
                   && UITestAnchors.frames["row." + plain.title] == nil,
               "subAsRow=\(UITestAnchors.frames["row." + "L5T due step"] != nil) quiet=\(UITestAnchors.frames["row." + quiet.title] != nil) plain=\(UITestAnchors.frames["row." + plain.title] != nil)")

        // The menu-bar queue and the Dock menu read the same pipeline as the list.
        let queued = MenuBarNextRows.rows(model: model, scope: .today, focusTaskID: nil, excluding: [], count: 20).map(\.title)
        record("today: the menu-bar next queue holds the parent, not the subtask",
               queued.contains(parent.title) && !queued.contains("L5T due step") && !queued.contains(plain.title),
               "queue=\(queued)")

        _ = await click("arrow." + parent.title)
        await settle(500)
        record("today: the due subtask is marked in the expanded parent",
               UITestAnchors.frames["subrow." + "L5T due step"] != nil && UITestAnchors.frames["subrow.due." + "L5T due step"] != nil,
               "subrow=\(UITestAnchors.frames["subrow." + "L5T due step"] != nil) marker=\(UITestAnchors.frames["subrow.due." + "L5T due step"] != nil)")

        if let step {
            store.toggleSubtaskNoUndo(step.id, isDone: true)
            model.didMutate()
            await settle(700)
            record("today: completing that subtask takes the parent out of Today",
                   UITestAnchors.frames["row." + parent.title] == nil, "stillThere=\(UITestAnchors.frames["row." + parent.title] != nil)")
        }
    }
}
#endif
