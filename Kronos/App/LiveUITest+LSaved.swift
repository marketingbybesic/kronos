// Live steps for saved views that belong to a project: a view saved from inside a project is listed under
// that project in the sidebar (not in the global section), opens that project's tasks with its own rules,
// shows its project locked in the options popover, keeps it through Clear all and is deleted from the row's
// context menu. Real clicks and keys in the real windows. Run alone with `--only group:L-SAVED`.
#if !RELEASE
import AppKit
import KronosCore

@MainActor
extension LiveUITest {
    static func lSavedSteps(_ model: AppModel) async {
        await runStep(model, scope: .all) { await lSavedFlow($0) }
    }

    private static var lSavedBreak: Bool { ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil }

    // MARK: Windows

    private static func lSavedPopoverWindows() -> [NSWindow] {
        NSApp.windows.filter { $0 !== window && $0.isVisible && $0.className.contains("Popover") }
    }

    /// Runs `body` with `win` as the test window (clicks and keys go to it), then restores.
    private static func lSavedIn(_ win: NSWindow?, _ body: () async -> Bool) async -> Bool {
        guard let main = window, let win else { return false }
        window = win
        defer { window = main }
        return await body()
    }

    private static func lSavedClosePopovers() async {
        for _ in 0..<3 where !lSavedPopoverWindows().isEmpty {
            key("\u{1b}", keyCode: 53)
            if await waitUntil(timeout: 1, { lSavedPopoverWindows().isEmpty }) { break }
            for pop in lSavedPopoverWindows() { _ = await lSavedIn(pop) { key("\u{1b}", keyCode: 53); return true } }
            await settle(200)
        }
        await settle(200)
    }

    private static func lSavedRows(_ model: AppModel, among titles: [String]) -> [String] {
        let want = Set(titles)
        return ListContext(model: model).rows.map(\.title).filter { want.contains($0) }.sorted()
    }

    private static func lSavedRealMenu(atAnchor id: String) -> NSMenu? {
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

    /// Scrolls the sidebar so the anchored row is on screen (a long sidebar keeps rows below the fold, where a
    /// click lands on nothing). False when no sidebar scroll view was found.
    @discardableResult
    private static func lSavedReveal(_ id: String) async -> Bool {
        guard let f = UITestAnchors.frames[id], let content = window.contentView else { return false }
        func scrollViews(_ v: NSView) -> [NSScrollView] {
            ((v as? NSScrollView).map { [$0] } ?? []) + v.subviews.flatMap(scrollViews)
        }
        let sidebar = scrollViews(content).first { content.convert($0.frame, from: $0.superview).minX < 320 && $0.frame.width < 400 }
        guard let sidebar, let doc = sidebar.documentView else { return false }
        let local = NSRect(x: f.minX, y: content.isFlipped ? f.minY : content.bounds.height - f.maxY, width: f.width, height: f.height)
        doc.scrollToVisible(doc.convert(local, from: content))
        await settle(400)
        return true
    }

    // MARK: The flow

    private static func lSavedFlow(_ model: AppModel) async {
        let store = model.store
        await setWindowSize(width: 1500, height: 900)
        model.sidebarIconsOnly = false
        // A long sidebar, as after other steps: the project below is out of sight until the row is revealed.
        let fillers = (0..<26).map { store.createProject(name: "lsaved.filler.\($0)") }
        let p = store.createProject(name: "lsaved.P")
        let q = store.createProject(name: "lsaved.Q")
        let pHigh1 = store.create(title: "lsaved.P.high1", project: p)
        let pLow = store.create(title: "lsaved.P.low", project: p)
        let pHigh2 = store.create(title: "lsaved.P.high2", project: p)
        let qHigh = store.create(title: "lsaved.Q.high", project: q)
        for t in [pHigh1, pHigh2, qHigh] { store.setPriority(t.id, .high) }
        store.setPriority(pLow.id, .low)
        let titles = [pHigh1, pLow, pHigh2, qHigh].map(\.title)
        let projectScope = ListScope.project(p.id)
        model.scope = projectScope
        model.searchText = ""
        model.didMutate()
        await settle(600)
        let existingViews = Set(store.allSavedViews().map(\.id))
        var created: [UUID] = []
        defer {
            for view in store.allSavedViews() where !existingViews.contains(view.id) { store.deleteSavedView(view.id) }
            for project in fillers + [p, q] { store.archiveProject(project.id) }
            for t in [pHigh1, pLow, pHigh2, qHigh] { store.softDelete(t.id) }
            model.scope = .all
            model.didMutate()
        }

        // 1. In project P: a rule is set, then "Save as view…" with the real popover and the real name field.
        var rule = KFilter()
        rule.priorities = [KPriority.high.rawValue]
        model.setOptions(ViewOptions(filter: rule), for: projectScope)
        await settle(400)
        NotificationCenter.default.post(name: .kronosViewOptionsRequested, object: nil)
        let optionsUp = await waitUntil(timeout: 4) { UITestAnchors.frames["viewoptions.saveview"] != nil && !lSavedPopoverWindows().isEmpty }
        await settle(300)
        let optionsWindow = lSavedPopoverWindows().first
        let clickedSave = await lSavedIn(optionsWindow) { await click("viewoptions.saveview") }
        let sheetUp = await waitUntil(timeout: 4) { UITestAnchors.frames["viewsave.name"] != nil && lSavedPopoverWindows().count >= 2 }
        await settle(300)
        let sheetWindow = lSavedPopoverWindows().min { $0.frame.height < $1.frame.height }
        let caption = UITestAnchors.frames["viewsave.project"] != nil
        let depth = store.undoDepth
        _ = await lSavedIn(sheetWindow) {
            await typeText("lsaved.view")
            await settle(200)
            key("\r", keyCode: 36)
            return true
        }
        let saved = await waitUntil(timeout: 4) { store.allSavedViews().contains { !existingViews.contains($0.id) } }
        await settle(500)
        let view = store.allSavedViews().first { !existingViews.contains($0.id) }
        if let view { created.append(view.id) }
        record("save from a project list: the sheet names the project and Return stores one view pinned to it with the rule kept",
               optionsUp && clickedSave && sheetUp && caption && saved && view?.name == "lsaved.view"
                 && (view?.homeProjectID == p.id) != lSavedBreak && view?.filter.priorities == [KPriority.high.rawValue]
                 && store.undoDepth == depth + 1,
               "options=\(optionsUp) click=\(clickedSave) sheet=\(sheetUp) caption=\(caption) saved=\(saved) name=\(view?.name ?? "nil") home=\(String(describing: view?.homeProjectID)) filter=\(String(describing: view?.filter.priorities)) steps=\(store.undoDepth - depth)")
        await lSavedClosePopovers()
        guard let view else { return }
        let scope = ListScope.savedView(view.id)

        // 2. The sidebar: the row is a child under P (between P and Q), and no global Views section exists.
        let rowID = "sidebar.view.\(view.id.uuidString)"
        let drawn = await waitUntil(timeout: 4) { UITestAnchors.frames[rowID] != nil && UITestAnchors.frames["sidebar.lsaved.P"] != nil }
        let py = UITestAnchors.frames["sidebar.lsaved.P"]?.minY ?? -1
        let qy = UITestAnchors.frames["sidebar.lsaved.Q"]?.minY ?? -1
        let vy = UITestAnchors.frames[rowID]?.minY ?? -1
        let globalNow = SidebarSavedViewsSection.globalViews(in: store).map(\.id)
        let headerGone = UITestAnchors.frames["sidebar.views.header"] == nil
        let underP = drawn && py < vy && vy < qy
        record("sidebar: the saved view is drawn directly under its project, before the next project, and not in a global Views section",
               underP && !globalNow.contains(view.id) && globalNow.isEmpty == headerGone,
               "drawn=\(drawn) P.y=\(Int(py)) view.y=\(Int(vy)) Q.y=\(Int(qy)) global=\(globalNow.count) headerGone=\(headerGone)")

        // 3. Selecting the row opens P's list with the view's rule.
        model.scope = .all
        await settle(500)
        let hidden = (UITestAnchors.frames[rowID]?.maxY ?? 0) > (window.contentView?.bounds.height ?? 0) - 120
        let revealed = await lSavedReveal(rowID)
        let clickedRow = await click(rowID)
        let opened = await waitUntil(timeout: 4) { model.scope == scope }
        await settle(600)
        let shown = lSavedRows(model, among: titles)
        record("selecting the view row lists only its project's tasks that match its rule",
               clickedRow && opened && shown == ["lsaved.P.high1", "lsaved.P.high2"] && UITestAnchors.frames["rules.bar"] != nil,
               "belowFold=\(hidden) revealed=\(revealed) click=\(clickedRow) scope=\(model.scope.storageKey) rows=\(shown) row=\(String(describing: UITestAnchors.frames[rowID]))")

        // 4. The popover shows the project as a locked row (no remove button, no editable project row);
        //    Clear all removes the rule and keeps the project.
        NotificationCenter.default.post(name: .kronosViewOptionsRequested, object: nil)
        let up = await waitUntil(timeout: 4) { UITestAnchors.frames["viewoptions.clearall"] != nil && !lSavedPopoverWindows().isEmpty }
        await settle(300)
        let locked = UITestAnchors.frames["filter.pinned"] != nil
            && UITestAnchors.frames["filter.remove.project"] == nil && UITestAnchors.frames["filter.row.project"] == nil
        let popWindow = lSavedPopoverWindows().first
        let cleared = await lSavedIn(popWindow) { await click("viewoptions.clearall") }
        await settle(700)
        let afterClear = lSavedRows(model, among: titles)
        let options = model.options(for: scope)
        let expectedRows = lSavedBreak ? titles.sorted() : ["lsaved.P.high1", "lsaved.P.high2", "lsaved.P.low"]
        record("popover: the project is a locked row, and Clear all removes the rule but keeps the project pin",
               up && locked && cleared && afterClear == expectedRows && options.filter == KFilter().pinned(to: p.id),
               "popover=\(up) locked=\(locked) click=\(cleared) rows=\(afterClear) pin=\(String(describing: options.filter.pinnedProjectID)) priorities=\(options.filter.priorities)")
        await lSavedClosePopovers()

        // 5. With nothing beyond the pin, Clear all is no longer offered.
        NotificationCenter.default.post(name: .kronosViewOptionsRequested, object: nil)
        let up2 = await waitUntil(timeout: 4) { UITestAnchors.frames["filter.pinned"] != nil && !lSavedPopoverWindows().isEmpty }
        await settle(300)
        let offered = UITestAnchors.frames["viewoptions.clearall"] != nil
        let barGone = UITestAnchors.frames["rules.bar"] == nil
        record("popover: only the project pin left, so Clear all is not offered and the rules bar (no pin chip, no X) is gone",
               up2 && !offered && barGone, "popover=\(up2) clearAllOffered=\(offered) barGone=\(barGone)")
        await lSavedClosePopovers()

        // 6. Options kept from an edit that lost the pin are put back when the row is selected again.
        model.setOptions(ViewOptions(), for: scope)
        model.scope = .all
        await settle(400)
        await lSavedReveal(rowID)
        _ = await click(rowID)
        _ = await waitUntil(timeout: 4) { model.scope == scope }
        await settle(600)
        let repaired = lSavedRows(model, among: titles)
        record("selecting a project view again restores its project when the stored options had lost it",
               repaired == ["lsaved.P.high1", "lsaved.P.high2", "lsaved.P.low"] && model.options(for: scope).filter.pinnedProjectID == p.id,
               "rows=\(repaired) pin=\(String(describing: model.options(for: scope).filter.pinnedProjectID))")

        // 6b. A task typed in the project's view goes to that project; typed in a view of no project it has none.
        let typed = QuickAddCreate.create(from: "lsaved.typed", model: model, scope: scope)
        let typedElsewhere = QuickAddCreate.create(from: "lsaved.typed.all", model: model, scope: .all)
        record("quick add inside a project's saved view files the task in that project; elsewhere it stays project-less",
               typed.first?.projectID == p.id && typedElsewhere.first?.projectID == nil,
               "inView=\(String(describing: typed.first?.projectID)) elsewhere=\(String(describing: typedElsewhere.first?.projectID))")
        for t in typed + typedElsewhere { store.softDelete(t.id) }
        model.didMutate()

        // 7. A view that belongs to no project is listed in the slim global section, not under a project.
        var legacyFilter = KFilter()
        legacyFilter.priorities = [KPriority.low.rawValue]
        let legacy = store.createSavedView(name: "lsaved.legacy", filter: legacyFilter, sort: [], showDone: false)
        created.append(legacy.id)
        model.didMutate()
        let legacyID = "sidebar.view.\(legacy.id.uuidString)"
        let legacyDrawn = await waitUntil(timeout: 4) { UITestAnchors.frames[legacyID] != nil && UITestAnchors.frames["sidebar.views.header"] != nil }
        let header = UITestAnchors.frames["sidebar.views.header"]?.minY ?? -1
        let legacyY = UITestAnchors.frames[legacyID]?.minY ?? -1
        let globalIDs = SidebarSavedViewsSection.globalViews(in: store).map(\.id)
        record("a view with no project is listed under the slim Views header, the project's view is not",
               legacyDrawn && header < legacyY && globalIDs == [legacy.id],
               "drawn=\(legacyDrawn) header.y=\(Int(header)) legacy.y=\(Int(legacyY)) global=\(globalIDs.count)")
        store.deleteSavedView(legacy.id)
        model.didMutate()
        let headerAway = await waitUntil(timeout: 4) { UITestAnchors.frames["sidebar.views.header"] == nil }
        record("the Views header is gone again once no project-less view is left", headerAway,
               "headerGone=\(headerAway)")

        // 8. Delete from the row's context menu: one undo step, a pill, the list goes back to the project,
        //    Cmd-Z brings the view back under the project.
        UndoToastCenter.shared.dismiss()
        let before = store.undoDepth
        await lSavedReveal(rowID)
        let menu = lSavedRealMenu(atAnchor: rowID)
        let item = menu?.items.first { $0.title == String(localized: "common.delete") }
        if let menu, let item { menu.performActionForItem(at: menu.index(of: item)) }
        let gone = await waitUntil(timeout: 4) { !store.allSavedViews().contains { $0.id == view.id } }
        await settle(500)
        let pill = UndoToastCenter.shared.current?.message ?? ""
        record("context menu Delete removes the view row, falls back to the project list, raises a pill, one undo step",
               menu != nil && item != nil && gone && model.scope == projectScope && pill.contains("lsaved.view")
                 && store.undoDepth == before + 1 && UITestAnchors.frames[rowID] == nil,
               "menu=\(menu != nil) item=\(item != nil) gone=\(gone) scope=\(model.scope.storageKey) pill=\"\(pill)\" steps=\(store.undoDepth - before) rowAnchor=\(UITestAnchors.frames[rowID] != nil)")
        store.undo()
        model.didMutate()
        let back = await waitUntil(timeout: 4) { store.allSavedViews().contains { $0.id == view.id } }
        let backRow = await waitUntil(timeout: 4) { UITestAnchors.frames[rowID] != nil }
        record("undo brings the deleted view back, under its project",
               back && backRow && store.allSavedViews().first { $0.id == view.id }?.homeProjectID == p.id && store.undoDepth == before,
               "back=\(back) row=\(backRow) steps=\(store.undoDepth - before)")
    }
}
#endif
