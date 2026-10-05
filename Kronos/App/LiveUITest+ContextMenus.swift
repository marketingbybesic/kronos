// Kronos/App/LiveUITest+ContextMenus.swift — live proof for the subtask / label / inspector-field
// context menus (see Kronos/List/ContextMenuTree.swift).
//
// What it proves, and how:
//  * ATTACHED: every menu is attached through `kContextMenu`, which registers the menu under the id
//    of the rendered view only while that view is on screen. A registry entry therefore means a
//    real row / chip / field of the running app carries the menu.
//  * REAL MENU when possible: it asks the view under the anchor for its context menu with a
//    synthetic right-click event (`NSView.menu(for:)`, no tracking loop) and, when AppKit hands one
//    back, drives the item through that real NSMenu. The detail of each step says which path ran
//    ("real-menu" or "closure"). When SwiftUI gives no NSMenu to an in-process caller, the step runs
//    the SAME action closure the menu item runs, found through the registry.
//  * ONE UNDO STEP: each action must push exactly one undo step; undo restores; a second pick of
//    the value the field already has pushes nothing.
// Compiled only outside Release (LiveUITest itself is).
#if !RELEASE
import AppKit
import KronosCore

@MainActor
extension LiveUITest {
    // MARK: Helpers

    /// A subtask by id, found through its person: nil once it is deleted or detached.
    private static func sub(_ store: TaskStore, _ id: UUID) -> KTask? {
        store.allTasks().flatMap { $0.orderedChildren }.first { $0.id == id }
    }

    /// Run one item of the menu registered under `menuID`. False when the menu is not attached to a
    /// rendered view, the item is missing, or it is disabled.
    @discardableResult
    private static func runItem(_ menuID: String, _ itemID: String) async -> Bool {
        guard await waitUntil({ CtxMenuRegistry.providers[menuID] != nil }),
              let nodes = CtxMenuRegistry.nodes(menuID) else { return false }
        let ran = CtxNodes.invoke(itemID, in: nodes)
        try? await Task.sleep(for: .milliseconds(250))
        return ran
    }

    /// The context menu AppKit builds for a right click on the view under an anchor, if any.
    private static func realMenu(atAnchor id: String) -> NSMenu? {
        guard let p = point(id), let content = window.contentView else { return nil }
        eventNumber += 1
        guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: p, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil,
                                             eventNumber: eventNumber, clickCount: 1, pressure: 1) else { return nil }
        var view = content.hitTest(content.convert(p, from: nil))
        while let current = view {
            if let menu = current.menu(for: event), !menu.items.isEmpty { return menu }
            view = current.superview
        }
        return nil
    }

    private static func menuItem(_ menu: NSMenu, _ titles: [String]) -> NSMenuItem? {
        var level: NSMenu? = menu
        var found: NSMenuItem?
        for title in titles {
            guard let item = level?.items.first(where: { $0.title == title }) else { return nil }
            found = item
            level = item.submenu
        }
        return found
    }

    /// Run `node` of `menu`; expect exactly one undo step, `after` true, and undo to restore (`restored`).
    private static func oneUndoStep(_ name: String, menu: String, node: String, model: AppModel,
                                    after: () -> Bool, restored: () -> Bool) async {
        let store = model.store
        let depth0 = store.undoDepth
        let ran = await runItem(menu, node)
        let depth1 = store.undoDepth
        let changed = after()
        store.undo()
        model.didMutate()
        try? await Task.sleep(for: .milliseconds(250))
        let depth2 = store.undoDepth
        let back = restored()
        record(name, ran && changed && depth1 == depth0 + 1 && back && depth2 == depth0,
               "ran=\(ran) changed=\(changed) undoDepth \(depth0)->\(depth1), after undo \(depth2) restored=\(back)")
    }

    // MARK: Step

    static func contextMenusStep(_ model: AppModel) async {
        let store = model.store
        let breakMode = ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil
        let mainWindow = window!
        var frame = mainWindow.frame
        frame.size = NSSize(width: 1500, height: 900)
        mainWindow.setFrame(frame, display: true)

        let parent = store.createNoUndo(title: "ctxmenu.parent")
        let other = store.createNoUndo(title: "ctxmenu.other")
        other.sortIndex = -1_000_000   // always inside the "Move under…" list, whatever else is in the store
        guard let s1 = store.addSubtaskNoUndo(parent.id, title: "ctxmenu.step.one"),
              let s2 = store.addSubtaskNoUndo(parent.id, title: "ctxmenu.step.two"),
              let s3 = store.addSubtaskNoUndo(parent.id, title: "ctxmenu.step.three") else {
            record("context menus: fixture subtasks", false, "addSubtaskNoUndo returned nil"); return
        }
        let (s1ID, s2ID, s3ID, parentID, otherID) = (s1.id, s2.id, s3.id, parent.id, other.id)
        let previousScope = model.scope
        model.scope = .all
        model.searchText = "ctxmenu"
        model.selectedTaskID = nil
        model.didMutate()
        try? await Task.sleep(for: .milliseconds(600))

        // 1. Middle list: open the parent's subtasks; every subtask row carries the menu.
        _ = await click("arrow.ctxmenu.parent")
        let rowsShown = await waitUntil { UITestAnchors.frames["subrow.ctxmenu.step.one"] != nil }
        let attached = [s1ID, s2ID, s3ID].allSatisfy { CtxMenuRegistry.providers["subrow.\($0.uuidString)"] != nil }
        record("subtask rows in the middle list carry a context menu", rowsShown && attached,
               "rowsShown=\(rowsShown) registered=\(CtxMenuRegistry.ids.filter { $0.hasPrefix("subrow.") }.count)")

        // 2. The menu holds exactly the contract's items, in order.
        if let nodes = CtxMenuRegistry.nodes("subrow.\(s1ID.uuidString)") {
            let top = nodes.filter { if case .divider = $0.kind { return false } else { return true } }.map(\.id)
            let due = CtxNodes.find("due", in: nodes).flatMap { n -> [String]? in
                if case .submenu(let kids) = n.kind { return kids.filter { if case .divider = $0.kind { return false } else { return true } }.map(\.id) }
                return nil
            } ?? []
            // Hand-written: a child task's menu = a task's menu minus breakdown and project move, plus
            // Make standalone task and Move under. The app passes withLink: "Copy Kronos link" follows Copy; "Avoiding it" (dread) follows Focus.
            let wantTop = ["complete", "focus", "dread", "details", "due", "priority", "status", "effort", "labels",
                           "standalone", "moveUnder", "copy", "copyLink", "delete"]
            let wantDue = ["due.today", "due.tomorrow", "due.nextweek", "due.pick", "due.clear"]
            let prio = (CtxNodes.find("priority", in: nodes).flatMap { n -> [String]? in
                if case .submenu(let kids) = n.kind { return kids.map(\.id) }
                return nil
            }) ?? []
            record("subtask menu items match the contract (Complete, Focus, Open details, Due, Priority, Status, Effort, Labels, Make standalone, Move under, Copy title, Delete)",
                   top == wantTop && due == wantDue && prio == ["priority.0", "priority.1", "priority.2", "priority.3", "priority.4"],
                   "top=\(top) due=\(due) priority=\(prio)")
        } else {
            record("subtask menu items match the contract", false, "no menu registered for the first subtask row")
        }

        // 3. Real right-click menu if AppKit gives one, else the closure; Copy title puts the title on the pasteboard.
        let real = realMenu(atAnchor: "ctx.subrow.\(s1ID.uuidString)")
        diagnostics.append("contextmenus: real NSMenu for a right click on a subtask row = \(real.map { "yes items=\($0.items.map(\.title))" } ?? "no (SwiftUI gave none in-process)")")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("sentinel", forType: .string)
        var path = "closure"
        if let real, let item = menuItem(real, [String(localized: "ctx.subtask.copy")]), let menu = item.menu {
            menu.performActionForItem(at: menu.index(of: item))
            path = "real-menu"
        } else {
            await runItem("subrow.\(s1ID.uuidString)", "copy")
        }
        let copied = NSPasteboard.general.string(forType: .string)
        record("subtask menu: Copy title puts the title on the pasteboard (\(path))", copied == "ctxmenu.step.one", "pasteboard=\(copied ?? "nil")")

        // 4. Complete / Reopen: one undo step; the title flips to Reopen once done.
        await oneUndoStep("subtask menu: Complete is one undo step", menu: "subrow.\(s1ID.uuidString)", node: "complete", model: model,
                          after: { breakMode ? sub(store, s1ID)?.isDone == false : sub(store, s1ID)?.isDone == true },
                          restored: { sub(store, s1ID)?.isDone == false })
        store.toggleSubtaskNoUndo(s1ID, isDone: true)
        model.didMutate()
        try? await Task.sleep(for: .milliseconds(300))
        let reopenTitle = CtxMenuRegistry.nodes("subrow.\(s1ID.uuidString)").flatMap { CtxNodes.find("complete", in: $0)?.title }
        record("subtask menu: a done subtask offers Reopen", reopenTitle == String(localized: "ctx.task.undone"), "title=\(reopenTitle ?? "nil")")
        store.toggleSubtaskNoUndo(s1ID, isDone: false)
        model.didMutate()

        // 5. Due / Priority go through the step setters; wired only when they exist in Core.
        do {
            await oneUndoStep("subtask menu: Priority is one undo step", menu: "subrow.\(s1ID.uuidString)", node: "priority.3", model: model,
                              after: { sub(store, s1ID)?.priorityRaw == 3 }, restored: { sub(store, s1ID)?.priorityRaw == 0 })
            await oneUndoStep("subtask menu: Due tomorrow is one undo step", menu: "subrow.\(s1ID.uuidString)", node: "due.tomorrow", model: model,
                              after: { sub(store, s1ID)?.dueDay == Day.today() + 1 }, restored: { sub(store, s1ID)?.dueDay == nil })
            let d0 = store.undoDepth
            let clearRan = await runItem("subrow.\(s1ID.uuidString)", "due.clear")
            record("subtask menu: Clear on an undated step is disabled and pushes nothing", !clearRan && store.undoDepth == d0, "ran=\(clearRan) depth \(d0)->\(store.undoDepth)")
        }

        // 5c. Labels on a child: the same flat Labels submenu a task has (one checked toggle per label,
        // one level deep); turning a label on is one undo step.
        let kidLabelID = store.label(named: "CtxChildLabel").id
        model.didMutate()
        try? await Task.sleep(for: .milliseconds(300))
        await oneUndoStep("child menu: Labels toggles a label on, one undo step", menu: "subrow.\(s1ID.uuidString)",
                          node: "label.\(kidLabelID.uuidString)", model: model,
                          after: { (sub(store, s1ID)?.labels ?? []).contains { $0.id == kidLabelID } },
                          restored: { !(sub(store, s1ID)?.labels ?? []).contains { $0.id == kidLabelID } })

        // 5d. Cmd-] / Cmd-[ on the child model. The actions run directly (the real key path is covered by
        // the nesting steps): a child can't nest deeper (refused, nothing pushed); the subtask the
        // inspector shows is promoted by Cmd-[ without needing row focus, one undo step.
        model.selectedTaskID = s1ID
        let nd0 = store.undoDepth
        NestingActions.nestSelected(model: model)
        record("Cmd-] on a subtask is refused and pushes nothing", store.undoDepth == nd0 && sub(store, s1ID)?.parentID == parentID,
               "depth \(nd0)->\(store.undoDepth) parent=\(String(describing: sub(store, s1ID)?.parentID))")
        model.selectedTaskID = parentID
        model.inspectedSubtaskID = s1ID
        NestingActions.promoteFocused(model: model)
        record("Cmd-[ promotes the subtask the inspector shows (one undo step)",
               store.undoDepth == nd0 + 1 && store.task(s1ID) != nil && store.task(s1ID)?.parentID == nil, "depth \(nd0)->\(store.undoDepth) parent=\(String(describing: sub(store, s1ID)?.parentID))")
        store.undo()
        model.inspectedSubtaskID = nil
        model.didMutate()
        record("Cmd-[ undo restores the subtask under its parent", sub(store, s1ID)?.parentID == parentID, "parent=\(String(describing: sub(store, s1ID)?.parentID))")

        // 5b. The same menu on a top-level task row: hand-written list, breakdown and project move
        // present, no standalone / move-under.
        if let rowNodes = CtxMenuRegistry.nodes("row.\(parentID.uuidString)") {
            let top = rowNodes.filter { if case .divider = $0.kind { return false } else { return true } }.map(\.id)
            record("task menu items (task row) match the contract",
                   top == ["complete", "focus", "dread", "breakdown", "details", "due", "priority", "status", "effort", "labels", "move", "copy", "copyLink", "savetemplate", "delete"],
                   "top=\(top)")
        } else {
            record("task menu items (task row) match the contract", false, "no menu registered for the parent row")
        }

        // 6. Move under: lands on the other task at the end; undo hands it back.
        await oneUndoStep("subtask menu: Move under another task is one undo step", menu: "subrow.\(s2ID.uuidString)",
                          node: "moveunder.\(otherID.uuidString)", model: model,
                          after: { sub(store, s2ID)?.parentID == otherID },
                          restored: { sub(store, s2ID)?.parentID == parentID })
        let targets = TaskMenu.moveTargets(parent: parent, model: model).map(\.id)
        record("subtask menu: Move under lists other tasks, never the parent", targets.contains(otherID) && !targets.contains(parentID),
               "targets=\(targets.count) hasOther=\(targets.contains(otherID)) hasParent=\(targets.contains(parentID))")

        // 7. Convert to task: a task with the subtask's title appears, the step is gone; undo reverses both.
        await oneUndoStep("subtask menu: Make standalone task is one undo step", menu: "subrow.\(s3ID.uuidString)", node: "standalone", model: model,
                          after: { sub(store, s3ID) == nil && store.allTasks().contains { $0.title == "ctxmenu.step.three" } },
                          restored: { sub(store, s3ID)?.parentID == parentID && !store.allTasks().contains { $0.title == "ctxmenu.step.three" } })

        // 8. Delete.
        await oneUndoStep("subtask menu: Delete is one undo step", menu: "subrow.\(s2ID.uuidString)", node: "delete", model: model,
                          after: { sub(store, s2ID) == nil },
                          restored: { sub(store, s2ID)?.parentID == parentID })

        // 9. Inspector: open Details (labels, status, depth, estimate live inside), steps carry the menu.
        let detailsWasOpen = UserDefaults.standard.bool(forKey: "kronos.inspector.detailsOpen")
        model.selectedTaskID = parentID
        model.didMutate()
        try? await Task.sleep(for: .milliseconds(600))
        if !detailsWasOpen { _ = await click("inspector.details.toggle"); try? await Task.sleep(for: .milliseconds(400)) }
        let label = store.label(named: "CtxLabel")
        let labelID = label.id
        store.addLabel(label, to: parentID)
        model.didMutate()
        try? await Task.sleep(for: .milliseconds(500))

        let stepAttached = await waitUntil { CtxMenuRegistry.providers["step.\(s1ID.uuidString)"] != nil }
        record("inspector steps carry the subtask context menu", stepAttached,
               "registered=\(CtxMenuRegistry.ids.filter { $0.hasPrefix("step.") }.count) anchor=\(UITestAnchors.frames["ctx.step.\(s1ID.uuidString)"] != nil)")
        await oneUndoStep("inspector step menu: Complete is one undo step", menu: "step.\(s1ID.uuidString)", node: "complete", model: model,
                          after: { sub(store, s1ID)?.isDone == true }, restored: { sub(store, s1ID)?.isDone == false })

        // 10. Label chip menu.
        let chip = "chip.\(labelID.uuidString)"
        let chipAttached = await waitUntil { CtxMenuRegistry.providers[chip] != nil }
        let chipItems = CtxMenuRegistry.nodes(chip).map { CtxNodes.ids($0).filter { !$0.hasPrefix("colour.") } } ?? []
        record("label chip carries Rename, Colour, Filter by label, Remove from task",
               chipAttached && chipItems == ["rename", "colour", "filter", "div", "remove"], "attached=\(chipAttached) items=\(chipItems)")
        let swatch = KProjectPalette.orderedSwatches[1].hex
        await oneUndoStep("label menu: Colour is one undo step and updates the label", menu: chip, node: "colour.\(swatch)", model: model,
                          after: { store.label(id: labelID)?.colorHex.uppercased() == "#" + swatch.uppercased() },
                          restored: { store.label(id: labelID)?.colorHex == "#8B8B93" })
        let optionsBefore = model.options(for: model.scope)
        let depthBeforeFilter = store.undoDepth
        await runItem(chip, "filter")
        let filtered = model.options(for: model.scope).filter.labelIDs == [labelID]
        await runItem(chip, "filter")
        record("label menu: Filter by label sets the list's label filter, pushes no undo step, repeats as a no-op",
               filtered && store.undoDepth == depthBeforeFilter, "filtered=\(filtered) depth \(depthBeforeFilter)->\(store.undoDepth)")
        model.setOptions(optionsBefore, for: model.scope)
        await oneUndoStep("label menu: Remove from task is one undo step", menu: chip, node: "remove", model: model,
                          after: { !(store.task(parentID)?.labels ?? []).contains { $0.id == labelID } },
                          restored: { (store.task(parentID)?.labels ?? []).contains { $0.id == labelID } })

        // 11. Inspector fields: quick value = one undo step; the same value again = nothing; Clear = one step.
        let day = Day.today()
        let table: [(field: String, node: String, set: () -> Bool, current: () -> Bool)] = [
            ("due", "tomorrow", { store.task(parentID)?.dueDay == day + 1 }, { store.task(parentID)?.dueDay == day + 1 }),
            ("priority", "3", { store.task(parentID)?.priority == .high }, { store.task(parentID)?.priority == .high }),
            ("effort", "3", { store.task(parentID)?.effort == .m }, { store.task(parentID)?.effort == .m }),
            ("estimate", "30", { store.task(parentID)?.estimateMinutes == 30 }, { store.task(parentID)?.estimateMinutes == 30 }),
            ("depth", "2", { store.task(parentID)?.depth == .deep }, { store.task(parentID)?.depth == .deep }),
            ("status", "\(KStatus.waiting.rawValue)", { store.task(parentID)?.status == .waiting }, { store.task(parentID)?.status == .waiting }),
        ]
        for row in table {
            let menu = "field.\(row.field).\(parentID.uuidString)"
            let attachedField = await waitUntil { CtxMenuRegistry.providers[menu] != nil }
            let d0 = store.undoDepth
            let ran = await runItem(menu, row.node)
            let d1 = store.undoDepth
            let set = row.set()
            let again = await runItem(menu, row.node)   // same value: the action runs but must change nothing
            let d2 = store.undoDepth
            record("inspector \(row.field) menu: quick value is one undo step, repeating it pushes nothing",
                   attachedField && ran && set && d1 == d0 + 1 && again && d2 == d1, "attached=\(attachedField) ran=\(ran) set=\(set) depth \(d0)->\(d1)->\(d2)")
            if row.field != "status" {
                let clearDepth = store.undoDepth
                let cleared = await runItem(menu, "clear")
                record("inspector \(row.field) menu: Clear is one undo step", cleared && !row.current() && store.undoDepth == clearDepth + 1,
                       "ran=\(cleared) stillSet=\(row.current()) depth \(clearDepth)->\(store.undoDepth)")
                let noop = await runItem(menu, "clear")   // already clear: disabled
                record("inspector \(row.field) menu: Clear on an empty field is disabled", !noop && store.undoDepth == clearDepth + 1, "ran=\(noop)")
            }
        }

        // Cleanup: nothing of this step may leak into later steps.
        if !detailsWasOpen { _ = await click("inspector.details.toggle") }
        model.searchText = ""
        model.scope = previousScope
        model.selectedTaskID = nil
        store.softDeleteNoUndo(parentID)
        store.softDeleteNoUndo(otherID)
        model.didMutate()
    }
}
#endif
