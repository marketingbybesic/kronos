// Live steps for the sidebar and the inspector's project field: archiving hides a project's tasks
// everywhere but the project itself, deleting an area is one undo step, a task row dropped on a
// project moves it, the Project field picks by typing, "Break down" from outside opens the preview,
// the drop hint shows once, and the new tooltips are set.
#if !RELEASE
import AppKit
import KronosCore

@MainActor
extension LiveUITest {
    static func cSidebarSteps(_ model: AppModel) async {
        await setWindowSize(width: 1500, height: 900)
        await resetState(model, scope: .today)
        await cArchiveHidesTasks(model)
        await resetState(model, scope: .today)
        await cDeleteAreaIsOneStep(model)
        await resetState(model, scope: .today)
        await cDropMovesTask(model)
        await resetState(model, scope: .all)
        await cProjectFieldPicks(model)
        await resetState(model, scope: .all)
        await cBreakdownRequest(model)
        await resetState(model, scope: .all)
        await cDropHintAndTooltips(model)
        await resetState(model, scope: .today)
    }

    private static var cBreakMode: Bool { ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil }

    private static func cUndo() async {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nil)
        key("z", modifiers: .command, keyCode: 6)
        await settle(500)
    }

    /// Cmd-Z through the real key, then the Edit menu item when the key did not land.
    private static func cUndoUntil(_ done: @MainActor () -> Bool) async {
        await cUndo()
        if !done(), let item = undoMenuItem(), let menu = item.menu {
            menu.performActionForItem(at: menu.index(of: item))
            await settle(400)
        }
    }

    // MARK: Archive

    /// Archiving from the menu action hides the project's open tasks from Today, the list, the Now
    /// pick and the menu bar pick; the pill names the project and the count; one Cmd-Z brings them back.
    private static func cArchiveHidesTasks(_ model: AppModel) async {
        let store = model.store
        let today = Day.today(calendar: KronosLocale.calendar)
        let project = store.createProject(name: "Archive probe", colorHex: "#4C9AFF", icon: nil, area: nil)
        let dueToday = store.create(title: "Archive probe due today", notes: "", project: project, status: .todo, priority: .none, dueDay: today)
        let open = store.create(title: "Archive probe open", notes: "", project: project, status: .todo, priority: .none, dueDay: nil)
        let done = store.create(title: "Archive probe done", notes: "", project: project, status: .todo, priority: .none, dueDay: nil)
        store.update(done.id) { $0.status = .done }
        model.scope = .today
        model.didMutate()
        await settle(400)
        let ids = [dueToday.id, open.id, done.id]
        defer { for id in ids { store.softDelete(id) }; model.didMutate() }

        let before = ListContext(model: model).rows.contains { $0.id == dueToday.id }
        let beforeBar = NextFallback.todayHead(store: store, today: today, limit: 500).contains(dueToday.id)
        UndoToastCenter.shared.dismiss()
        let depth = store.undoDepth
        SidebarMenuActions.archiveProject(project, model: model)
        await settle(500)

        let rows = ListContext(model: model).rows.map(\.id)
        let inList = rows.contains(dueToday.id)
        let bar = NextFallback.todayHead(store: store, today: today, limit: 500).contains(dueToday.id)
        let excluded = store.task(dueToday.id).map { NextEligibility.exclusion(of: $0, lookup: store.allTasks()) } ?? nil
        let counted = store.task(dueToday.id).map { ScopeFilter.countsInSidebar($0, scope: .today, today: today) } ?? true
        let message = UndoToastCenter.shared.current?.message ?? ""
        let pill = message.contains("Archive probe") && message.contains("2") && message.contains("·")
        let hiddenWanted = !cBreakMode
        record("archive hides the project's open tasks from Today, the list, Now and the bar, the pill names the project and the count",
               before && beforeBar && (hiddenWanted ? (!inList && !bar && !counted) : (inList && bar && counted))
                 && excluded == .projectArchived && pill && store.undoDepth == depth + 1,
               "before=\(before)/\(beforeBar) inList=\(inList) bar=\(bar) counted=\(counted) excluded=\(String(describing: excluded)) pill=\"\(message)\" steps=\(store.undoDepth - depth)")

        await cUndoUntil { store.task(dueToday.id)?.isProjectArchived == false }
        let back = ListContext(model: model).rows.contains { $0.id == dueToday.id }
        record("one Cmd-Z restores the archived project's tasks to Today",
               back && store.task(dueToday.id)?.isProjectArchived == false && store.undoDepth == depth,
               "back=\(back) archived=\(String(describing: store.task(dueToday.id)?.isProjectArchived)) depth \(depth)->\(store.undoDepth)")
    }

    // MARK: Delete area

    /// Delete area keeps the projects (area-less), is one undo step, raises the pill, and Cmd-Z brings the area back.
    private static func cDeleteAreaIsOneStep(_ model: AppModel) async {
        let store = model.store
        let area = store.createArea(name: "Delete probe")
        let p1 = store.createProject(name: "Delete probe one", colorHex: "#4C9AFF", icon: nil, area: area)
        let p2 = store.createProject(name: "Delete probe two", colorHex: "#27AE60", icon: nil, area: area)
        let task = store.create(title: "Delete probe task", notes: "", project: p1, status: .todo, priority: .none, dueDay: nil)
        model.didMutate()
        await settle(300)
        defer { store.softDelete(task.id); model.didMutate() }
        UndoToastCenter.shared.dismiss()
        let depth = store.undoDepth
        SidebarMenuActions.deleteArea(area, model: model)
        await settle(500)
        let areaGone = !store.allAreas().contains { $0.id == area.id }
        let released = store.allProjects(includeArchived: true).filter { $0.id == p1.id || $0.id == p2.id }.allSatisfy { $0.area == nil }
        let message = UndoToastCenter.shared.current?.message ?? ""
        record("Delete area keeps its projects without an area, in one undo step, with a pill naming it",
               areaGone && released && store.undoDepth == depth + 1 && message.contains("Delete probe") && store.task(task.id)?.projectID == p1.id,
               "areaGone=\(areaGone) released=\(released) steps=\(store.undoDepth - depth) pill=\"\(message)\"")
        await cUndoUntil { store.allAreas().contains { $0.id == area.id } }
        record("one Cmd-Z brings a deleted area back",
               store.allAreas().contains { $0.id == area.id } && store.undoDepth == depth,
               "back=\(store.allAreas().contains { $0.id == area.id }) depth \(depth)->\(store.undoDepth)")
    }

    // MARK: Task row dropped on a project

    /// A task row dragged onto a project row moves it (one undo step, a pill); a same-project drop, a step and a
    /// plain text drop change nothing. Driven with a pasteboard of its own through the code the row's drop calls.
    private static func cDropMovesTask(_ model: AppModel) async {
        let store = model.store
        let project = store.createProject(name: "Drop probe", colorHex: "#F2994A", icon: nil, area: nil)
        let task = store.create(title: "Drop probe task", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
        let step = store.addSubtask(task.id, title: "Drop probe step")
        model.didMutate()
        await settle(300)
        defer { store.softDelete(task.id); model.didMutate() }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("kronos.csidebar.livetest"))
        defer { pasteboard.releaseGlobally() }

        func offer(_ text: String) {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
        UndoToastCenter.shared.dismiss()
        let depth = store.undoDepth
        offer(DropZonePayloadReader.taskDragString(task.id))
        let accepted = SidebarTaskDrop.kind(of: pasteboard) == .task(task.id)
        let moved = SidebarTaskDrop.perform(pasteboard, onProject: project.id, model: model)
        await settle(300)
        let filed = store.task(task.id)?.projectID == project.id
        let message = UndoToastCenter.shared.current?.message ?? ""
        let wantMoved = !cBreakMode
        record("a task row dropped on a project moves it in one undo step with a pill",
               accepted && moved == wantMoved && filed == wantMoved && store.undoDepth == depth + 1 && message.contains("Drop probe"),
               "accepted=\(accepted) moved=\(moved) filed=\(filed) steps=\(store.undoDepth - depth) pill=\"\(message)\"")

        let again = SidebarTaskDrop.perform(pasteboard, onProject: project.id, model: model)
        offer(DropZonePayloadReader.subtaskDragString(step?.id ?? UUID()))
        let stepRefused = SidebarTaskDrop.kind(of: pasteboard) == nil && !SidebarTaskDrop.perform(pasteboard, onProject: project.id, model: model)
        offer("just some words")
        let textRefused = SidebarTaskDrop.kind(of: pasteboard) == nil
        record("a same-project drop, a step and plain text are refused without a write",
               !again && stepRefused && textRefused && store.undoDepth == depth + 1,
               "again=\(again) stepRefused=\(stepRefused) textRefused=\(textRefused) steps=\(store.undoDepth - depth)")

        await cUndoUntil { store.task(task.id)?.projectID == nil }
        record("one Cmd-Z puts the dropped task back where it was",
               store.task(task.id)?.projectID == nil && store.undoDepth == depth,
               "project=\(String(describing: store.task(task.id)?.projectID)) depth \(depth)->\(store.undoDepth)")
    }

    // MARK: Project field

    private static func cTypeInPicker(_ text: String) async {
        await waitUntil(timeout: 2) { window.firstResponder is NSTextView }
        await typeText(text)
        await settle(250)
    }

    /// The inspector's Project field is in the summary; click opens the picker, typing ranks, Return files
    /// the task; Up/Down move the highlight; Esc and an equal pick change nothing.
    private static func cProjectFieldPicks(_ model: AppModel) async {
        let store = model.store
        let kodiak = store.createProject(name: "Zqx Kodiak", colorHex: "#4C9AFF", icon: nil, area: nil)
        let kitchen = store.createProject(name: "Zqx Kitchen", colorHex: "#F2994A", icon: nil, area: nil)
        let task = store.create(title: "Project field probe", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
        model.didMutate()
        model.selectedTaskID = task.id
        await settle(700)
        defer { store.softDelete(task.id); model.selectedTaskID = nil; model.didMutate() }

        let frame = UITestAnchors.frames["inspector.project"]
        let big = (frame?.width ?? 0) >= Metrics.minHit && (frame?.height ?? 0) >= Metrics.minHit
        record("the Project field is in the inspector summary and its hit target is at least 24 pt",
               frame != nil && big, "frame=\(String(describing: frame))")

        UndoToastCenter.shared.dismiss()
        let depth = store.undoDepth
        let opened = await click("inspector.project")
        await waitUntil(timeout: 3) { UITestAnchors.frames["projectpicker.field"] != nil }
        let shown = UITestAnchors.frames["projectpicker.field"] != nil
        await cTypeInPicker("zqx kod")
        let rowFrame = UITestAnchors.frames["projectpicker.row.Zqx Kodiak"]
        let rowBig = (rowFrame?.height ?? 0) >= Metrics.minHit && (rowFrame?.width ?? 0) >= Metrics.minHit
        key("\r", keyCode: 36)
        await waitUntil(timeout: 3) { store.task(task.id)?.projectID == kodiak.id }
        await settle(300)
        let picked = store.task(task.id)?.projectID == kodiak.id
        let closed = UITestAnchors.frames["projectpicker.field"] == nil
        let message = UndoToastCenter.shared.current?.message ?? ""
        record("Project field: click, type a few letters, Return files the task in that project, one undo step and a pill",
               opened && shown && picked == !cBreakMode && closed && rowBig && store.undoDepth == depth + 1 && message.contains("Zqx Kodiak"),
               "opened=\(opened) shown=\(shown) picked=\(picked) closed=\(closed) rowFrame=\(String(describing: rowFrame)) steps=\(store.undoDepth - depth) pill=\"\(message)\"")

        // Keyboard only from here: type, Down, Return. The project used last leads the equal matches.
        let depth2 = store.undoDepth
        _ = await click("inspector.project")
        await waitUntil(timeout: 3) { UITestAnchors.frames["projectpicker.field"] != nil }
        await cTypeInPicker("zqx")
        key("\u{F701}", keyCode: 125)
        await settle(200)
        key("\r", keyCode: 36)
        await waitUntil(timeout: 3) { store.task(task.id)?.projectID == kitchen.id }
        await settle(300)
        let second = store.task(task.id)?.projectID == kitchen.id
        record("Project picker keyboard path: the project used last leads, Down then Return picks the next one",
               second && store.undoDepth == depth2 + 1,
               "kitchen=\(second) steps=\(store.undoDepth - depth2)")

        // Esc closes without a change; an equal pick writes nothing.
        let depth3 = store.undoDepth
        _ = await click("inspector.project")
        await waitUntil(timeout: 3) { UITestAnchors.frames["projectpicker.field"] != nil }
        await waitUntil(timeout: 2) { window.firstResponder is NSTextView }
        // The field takes focus one run-loop hop after it appears; Esc before that goes to nobody.
        await settle(400)
        key("\u{1B}", keyCode: 53)
        await settle(400)
        let escClosed = UITestAnchors.frames["projectpicker.field"] == nil
        _ = await click("inspector.project")
        await waitUntil(timeout: 3) { UITestAnchors.frames["projectpicker.field"] != nil }
        await cTypeInPicker("zqx kit")
        key("\r", keyCode: 36)
        await settle(500)
        record("Esc closes the picker and an equal pick writes nothing",
               escClosed && store.task(task.id)?.projectID == kitchen.id && store.undoDepth == depth3
                 && UITestAnchors.frames["projectpicker.field"] == nil,
               "escClosed=\(escClosed) depth \(depth3)->\(store.undoDepth) project=\(store.task(task.id)?.projectID == kitchen.id)")
    }

    // MARK: Break down from outside

    /// A request filed from outside opens the preview without a click; Cmd-Return adds the steps and does not complete the task.
    private static func cBreakdownRequest(_ model: AppModel) async {
        let store = model.store
        let task = store.create(title: "Plan the quarterly offsite and book the travel", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
        let other = store.create(title: "Breakdown request other", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
        model.didMutate()
        model.selectedTaskID = task.id
        await settle(700)
        defer { store.softDelete(task.id); store.softDelete(other.id); model.selectedTaskID = nil; model.didMutate() }

        // A request for another task, or an expired one, is not taken (hand table).
        let requests = BreakdownRequests.shared
        let stamp = Date()
        requests.request(taskID: other.id, now: stamp)
        let wrongTask = !requests.take(for: task.id, now: stamp) && requests.pendingTaskID == other.id
        let expired = !requests.take(for: other.id, now: stamp.addingTimeInterval(BreakdownRequests.lifetime + 1)) && requests.pendingTaskID == nil
        let fresh: Bool = {
            requests.request(taskID: other.id, now: stamp)
            return requests.take(for: other.id, now: stamp.addingTimeInterval(1)) && requests.pendingTaskID == nil
        }()
        record("a break-down request is taken once, only by its task, and only while it is fresh",
               wrongTask && expired && fresh, "wrongTask=\(wrongTask) expired=\(expired) fresh=\(fresh)")

        let before = UITestAnchors.frames["inspector.breakdown.preview"] != nil
        let depth = store.undoDepth
        requests.request(taskID: task.id)
        await waitUntil(timeout: 3) { UITestAnchors.frames["inspector.breakdown.preview"] != nil }
        let opened = UITestAnchors.frames["inspector.breakdown.preview"] != nil
        record("a break-down request from outside opens the preview without a click",
               !before && opened == !cBreakMode, "before=\(before) opened=\(opened)")

        await settle(400)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nil)
        key("\r", modifiers: .command, keyCode: 36)
        await waitUntil(timeout: 3) { !(store.task(task.id)?.orderedSubtasks.isEmpty ?? true) }
        await settle(300)
        let steps = store.task(task.id)?.orderedSubtasks.count ?? 0
        let notDone = store.task(task.id)?.status != .done
        record("Cmd-Return in the preview adds the steps in one undo step and does not complete the task",
               steps > 0 && notDone && store.undoDepth == depth + 1 && UITestAnchors.frames["inspector.breakdown.preview"] == nil,
               "steps=\(steps) notDone=\(notDone) undoSteps=\(store.undoDepth - depth) previewGone=\(UITestAnchors.frames["inspector.breakdown.preview"] == nil)")
    }

    // MARK: Drop hint and tooltips

    private static func cDropHintAndTooltips(_ model: AppModel) async {
        let store = model.store
        let a = store.create(title: "Hint probe one", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
        let b = store.create(title: "Hint probe two", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
        let c = store.create(title: "Hint probe three", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
        model.didMutate()
        defer { for t in [a, b, c] { store.softDelete(t.id) }; model.selectedTaskID = nil; model.didMutate() }
        let iconsOnly = model.sidebarIconsOnly
        let detailsWasOpen = UserDefaults.standard.bool(forKey: "kronos.inspector.detailsOpen")
        defer { model.sidebarIconsOnly = iconsOnly }
        model.sidebarIconsOnly = false

        KronosEnv.defaults.removeObject(forKey: InspectorDropHint.seenKey)
        model.selectedTaskID = a.id
        await waitUntil(timeout: 3) { UITestAnchors.frames["inspector.drophint"] != nil }
        let shownFirst = UITestAnchors.frames["inspector.drophint"] != nil
        model.selectedTaskID = b.id
        await settle(500)
        let goneForSecond = UITestAnchors.frames["inspector.drophint"] == nil
        model.selectedTaskID = c.id
        await settle(500)
        let goneAfter = UITestAnchors.frames["inspector.drophint"] == nil
        let flag = KronosEnv.defaults.bool(forKey: InspectorDropHint.seenKey)
        record("the drop hint shows under Links once and is gone for the next task",
               shownFirst && goneAfter == !cBreakMode && goneForSecond && flag,
               "shownFirst=\(shownFirst) goneForSecond=\(goneForSecond) goneAfter=\(goneAfter) flag=\(flag)")

        if !detailsWasOpen { _ = await click("inspector.details.toggle"); await settle(500) }
        let tips = Set(window.contentView?.collectToolTips() ?? [])
        let wanted = [
            String(localized: "sidebar.help.inbox"), String(localized: "sidebar.help.today"), String(localized: "sidebar.help.next7"),
            String(localized: "sidebar.help.waiting"), String(localized: "sidebar.help.someday"), String(localized: "sidebar.help.all"),
            String(localized: "sidebar.help.sort"), String(localized: "sidebar.help.pickone"),
            String(localized: "detail.help.project"), String(localized: "detail.help.dread"), String(localized: "detail.help.depth"),
            String(localized: "detail.help.estimate"), String(localized: "detail.help.waiting"), String(localized: "detail.help.breakdown"),
            String(localized: "detail.help.focus"),
        ]
        let missing = wanted.filter { !tips.contains($0) }
        let tooLong = tips.filter { $0.count > 75 }
        if !detailsWasOpen { _ = await click("inspector.details.toggle"); await settle(300) }
        record("the sidebar rows and inspector fields carry their tooltips, none longer than 75 characters",
               missing.isEmpty && tooLong.isEmpty && !wanted.contains(""),
               "missing=\(missing) tooLong=\(tooLong) total=\(tips.count)")
    }
}
#endif
