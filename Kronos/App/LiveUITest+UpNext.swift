// Kronos/App/LiveUITest+UpNext.swift
// Live steps for Send to Up next (ORDO) — Kronos/Commands/UpNextActions.swift: one selected row
// goes through `TaskStore.sendToOrdo` directly (⌘⇧O append, ⌥⌘⇧O top), 2+ selected rows go
// through `ListBulk.apply(.sendToUpNext(top:))` instead (one undo step for the whole batch, the
// bulk bar's "bulk.upnext" menu), and the row's own context-menu items
// (`TaskMenu.sendToUpNextNodeID` / `sendToUpNextTopNodeID`, TaskContextMenu.swift) write the same
// way. Run alone with `--only group:UP-NEXT`.
#if !RELEASE
import AppKit
import KronosCore

@MainActor
extension LiveUITest {
    static func upNextSteps(_ model: AppModel) async {
        await runStep(model, scope: .all) { await upNextSingle($0) }
        await runStep(model, scope: .all) { await upNextBulk($0) }
        await runStep(model, scope: .all) { await upNextContextMenu($0) }
        await runStep(model, scope: .all) { await upNextHotkeys($0) }
    }

    // MARK: Helpers

    /// Probe rows at the top of Manual order, so a shift-down range selection is deterministic.
    private static func upNextProbes(_ model: AppModel, _ titles: [String]) async -> [KTask] {
        let store = model.store
        let floor = (store.allTasks().map(\.sortIndex).min() ?? 0) - Double(titles.count + 1) * 1024
        let tasks = titles.enumerated().map { i, title -> KTask in
            let t = store.createNoUndo(title: title, notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
            store.updateNoUndo(t.id) { $0.sortIndex = floor + Double(i) * 1024 }
            return t
        }
        model.didMutate()
        if let last = titles.last { await waitUntil(timeout: 4) { UITestAnchors.frames["row." + last] != nil } }
        await settle(300)
        return tasks
    }

    @discardableResult
    private static func upNextSelect(_ model: AppModel, _ task: KTask) async -> Bool {
        model.selectedIDs = []
        let clicked = await click("row." + task.title, xFraction: 0.45)
        let ok = await waitUntil(timeout: 2) { model.selectedTaskID == task.id }
        await settle(150)
        return clicked && ok
    }

    private static func upNextPillSays(_ text: String) -> Bool {
        UndoToastCenter.shared.current?.message.contains(text) == true
    }

    @discardableResult
    private static func upNextUndo() -> Bool {
        guard let item = undoMenuItem(), let menu = item.menu else { return false }
        menu.performActionForItem(at: menu.index(of: item))
        return true
    }

    /// The View-menu item (`CommandGroup(after: .toolbar)`, KronosApp.swift) for ⌘⇧O (append) or
    /// ⌥⌘⇧O (top) — both share the "o" key equivalent, the modifier mask tells them apart, same
    /// lookup shape `bracketItem` uses for Cmd-]/Cmd-[ in LiveUITest+Nesting.swift.
    private static func upNextMenuItem(top: Bool) -> NSMenuItem? {
        let want: NSEvent.ModifierFlags = top ? [.command, .shift, .option] : [.command, .shift]
        func find(_ menu: NSMenu?) -> NSMenuItem? {
            for item in menu?.items ?? [] {
                if item.keyEquivalent == "o", item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == want {
                    return item
                }
                if let hit = find(item.submenu) { return hit }
            }
            return nil
        }
        return find(NSApp.mainMenu)
    }

    // MARK: Single row: append, top, undo

    private static func upNextSingle(_ model: AppModel) async {
        let store = model.store
        let p = await upNextProbes(model, ["upnext.single.a", "upnext.single.b"])

        _ = await upNextSelect(model, p[0])
        let depth = store.undoDepth
        UpNextActions.send(top: false, model: model)
        await waitUntil { store.task(p[0].id)?.ordoIndex != nil }
        let appended = store.task(p[0].id)?.ordoIndex
        record("a single selected row: Send to Up next sets its ordoIndex, one undo step, with the pill",
               appended != nil && store.undoDepth - depth == 1 && upNextPillSays(p[0].title),
               "ordoIndex=\(String(describing: appended)) steps=\(store.undoDepth - depth) pill=\(UndoToastCenter.shared.current?.message ?? "nil")")

        _ = await upNextSelect(model, p[1])
        let depth2 = store.undoDepth
        UpNextActions.send(top: true, model: model)
        await waitUntil { store.task(p[1].id)?.ordoIndex != nil }
        let topIdx = store.task(p[1].id)?.ordoIndex
        record("Send to Up next (top) lands ahead of the already-appended row, one undo step, with the pill",
               (topIdx ?? .infinity) < (appended ?? -.infinity) && store.undoDepth - depth2 == 1 && upNextPillSays(p[1].title),
               "top=\(String(describing: topIdx)) appended=\(String(describing: appended)) steps=\(store.undoDepth - depth2)")

        let depth3 = store.undoDepth
        let undone = upNextUndo()
        await waitUntil { store.task(p[1].id)?.ordoIndex == nil }
        record("one Undo clears the top row's ordoIndex and leaves the other row's untouched",
               undone && store.task(p[1].id)?.ordoIndex == nil && store.task(p[0].id)?.ordoIndex == appended
                   && store.undoDepth == depth3 - 1,
               "p1=\(String(describing: store.task(p[1].id)?.ordoIndex)) p0=\(String(describing: store.task(p[0].id)?.ordoIndex))")

        UndoToastCenter.shared.dismiss()
        store.updateNoUndo(p[0].id) { $0.ordoIndex = nil }
        model.selectedIDs = []
    }

    // MARK: 2+ selected: ListBulk.apply, the bulk bar

    private static func upNextBulk(_ model: AppModel) async {
        let store = model.store
        let p = await upNextProbes(model, ["upnext.bulk.a", "upnext.bulk.b"])
        let sel = await upNextSelect(model, p[0])
        let down = String(UnicodeScalar(0xF701)!)
        key(down, modifiers: [.shift, .numericPad, .function], keyCode: 125)
        let twoSelected = await waitUntil(timeout: 2) { model.selectedIDs.count == 2 }
        await settle(200)
        let barShown = await waitUntil(timeout: 2) { UITestAnchors.frames["bulk.upnext"] != nil }
        record("2 rows selected (⇧↓ from the anchor): the bulk bar offers Up next",
               sel && twoSelected && barShown, "selected=\(model.selectedIDs.count) bar=\(barShown)")

        let depth = store.undoDepth
        // 2+ selected: UpNextActions.send routes to ListBulk.apply(.sendToUpNext(top:)) itself
        // (Kronos/Commands/UpNextActions.swift), the same call the bulk bar's menu makes.
        UpNextActions.send(top: false, model: model)
        await waitUntil { p.allSatisfy { store.task($0.id)?.ordoIndex != nil } }
        let aIdx = store.task(p[0].id)?.ordoIndex, bIdx = store.task(p[1].id)?.ordoIndex
        record("appending 2 selected rows is ONE undo step for the whole batch and keeps list order (a before b)",
               (aIdx ?? .infinity) < (bIdx ?? .infinity) && store.undoDepth - depth == 1,
               "a=\(String(describing: aIdx)) b=\(String(describing: bIdx)) steps=\(store.undoDepth - depth)")

        let undone = upNextUndo()
        await waitUntil { p.allSatisfy { store.task($0.id)?.ordoIndex == nil } }
        record("one undo clears ordoIndex on both rows from the batch",
               undone && p.allSatisfy { store.task($0.id)?.ordoIndex == nil },
               "a=\(String(describing: store.task(p[0].id)?.ordoIndex)) b=\(String(describing: store.task(p[1].id)?.ordoIndex))")

        // Push to top: TaskStore.sendToOrdo(_:[UUID],top:true) (the canonical multi-send
        // ListBulkActions calls) iterates the ordered ids in REVERSE, so the selection keeps
        // its list order with the FIRST row (a) frontmost — the original ascending loop
        // stacked each later push above the previous one and reversed the pair, which the
        // round-5 review flagged and the store-level rewrite fixed (IndexArithmeticTests'
        // multiSendTopPreservesListOrderWithFirstIDFrontmost is the unit-level proof).
        let depth2 = store.undoDepth
        UpNextActions.send(top: true, model: model)
        await waitUntil { p.allSatisfy { store.task($0.id)?.ordoIndex != nil } }
        let aTop = store.task(p[0].id)?.ordoIndex, bTop = store.task(p[1].id)?.ordoIndex
        record("pushing 2 selected rows to the top is one undo step and keeps list order (a frontmost)",
               (aTop ?? .infinity) < (bTop ?? .infinity) && store.undoDepth - depth2 == 1,
               "a=\(String(describing: aTop)) b=\(String(describing: bTop)) steps=\(store.undoDepth - depth2)")

        UndoToastCenter.shared.dismiss()
        model.selectedIDs = []
        for t in p { store.updateNoUndo(t.id) { $0.ordoIndex = nil } }
    }

    // MARK: Row context menu

    private static func upNextContextMenu(_ model: AppModel) async {
        let store = model.store
        let p = await upNextProbes(model, ["upnext.menu.a"])
        _ = await upNextSelect(model, p[0])
        guard let nodes = CtxMenuRegistry.nodes("row.\(p[0].id.uuidString)") else {
            record("the task row carries its context menu", false, "registered=\(CtxMenuRegistry.ids.prefix(8))"); return
        }
        let shown = CtxNodes.visible(nodes)
        let hasAppend = shown.contains { $0.id == TaskMenu.sendToUpNextNodeID }
        let hasTop = shown.contains { $0.id == TaskMenu.sendToUpNextTopNodeID }
        record("a top-level task's row menu carries both Send to Up next items",
               hasAppend && hasTop, "ids=\(shown.map(\.id))")

        let depth = store.undoDepth
        let ran = CtxNodes.invoke(TaskMenu.sendToUpNextNodeID, in: CtxMenuRegistry.nodes("row.\(p[0].id.uuidString)") ?? [])
        await settle(150)
        record("invoking Send to Up next from the row menu sets ordoIndex, one undo step, with the pill",
               ran && store.task(p[0].id)?.ordoIndex != nil && store.undoDepth - depth == 1 && upNextPillSays(p[0].title),
               "ran=\(ran) ordoIndex=\(String(describing: store.task(p[0].id)?.ordoIndex)) steps=\(store.undoDepth - depth)")

        UndoToastCenter.shared.dismiss()
        store.updateNoUndo(p[0].id) { $0.ordoIndex = nil }
        model.selectedIDs = []
    }

    // MARK: Hotkeys

    private static func upNextHotkeys(_ model: AppModel) async {
        let store = model.store
        guard let appendItem = upNextMenuItem(top: false), let topItem = upNextMenuItem(top: true) else {
            record("the View menu carries Send to Up next and Send to Up next (top)", false,
                   "append=\(upNextMenuItem(top: false) != nil) top=\(upNextMenuItem(top: true) != nil)")
            return
        }
        record("the View menu carries Send to Up next and Send to Up next (top)", true, "")

        let appendBinding = HotkeyRegistry.current(for: "list.sendtoupnext")
        let topBinding = HotkeyRegistry.current(for: "list.sendtoupnexttop")
        record("HotkeyRegistry carries both ids, both on O, only the top one with Option",
               appendBinding?.key == "o" && appendBinding?.shift == true && appendBinding?.command == true
                   && appendBinding?.option == false
                   && topBinding?.key == "o" && topBinding?.shift == true && topBinding?.command == true
                   && topBinding?.option == true,
               "append=\(String(describing: appendBinding)) top=\(String(describing: topBinding))")

        let p = await upNextProbes(model, ["upnext.hotkey.a"])
        _ = await upNextSelect(model, p[0])
        key("o", modifiers: [.command, .shift], keyCode: 31)
        var viaKey = await waitUntil(timeout: 2) { store.task(p[0].id)?.ordoIndex != nil }
        if !viaKey, let menu = appendItem.menu {
            menu.performActionForItem(at: menu.index(of: appendItem))
            viaKey = await waitUntil(timeout: 2) { store.task(p[0].id)?.ordoIndex != nil }
        }
        record("⌘⇧O sends the selected row to Up next (real key event, menu item fallback noted)",
               store.task(p[0].id)?.ordoIndex != nil, "deliveredByKey=\(viaKey)")
        store.updateNoUndo(p[0].id) { $0.ordoIndex = nil }

        _ = await upNextSelect(model, p[0])
        key("o", modifiers: [.command, .shift, .option], keyCode: 31)
        var viaKeyTop = await waitUntil(timeout: 2) { store.task(p[0].id)?.ordoIndex != nil }
        if !viaKeyTop, let menu = topItem.menu {
            menu.performActionForItem(at: menu.index(of: topItem))
            viaKeyTop = await waitUntil(timeout: 2) { store.task(p[0].id)?.ordoIndex != nil }
        }
        record("⌥⌘⇧O sends the selected row to Up next (top) (real key event, menu item fallback noted)",
               store.task(p[0].id)?.ordoIndex != nil, "deliveredByKey=\(viaKeyTop)")

        UndoToastCenter.shared.dismiss()
        store.updateNoUndo(p[0].id) { $0.ordoIndex = nil }
        model.selectedIDs = []
    }
}
#endif
