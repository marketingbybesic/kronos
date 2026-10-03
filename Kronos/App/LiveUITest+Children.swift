// Kronos/App/LiveUITest+Children.swift — live proof of the child rows in the middle list: the marks a
// child carries, the three ways to open its details (info button, double-click, Return on the focused
// row) and the drop engine on the child-task model (a task dropped onto a child row becomes its sibling
// under the same parent, a task with children flattens, one undo step each). Real clicks and key events
// posted to the window, the scripted drag of LiveUITest+Drop for the drops.
// Compiled only outside Release, like every live step.
#if !RELEASE
import AppKit
import KronosCore

@MainActor
extension LiveUITest {
    /// A left click `count` times in a row at `p` (the second down carries clickCount 2, like a real double-click).
    private static func multiClick(_ p: NSPoint, count: Int) async {
        if !NSApp.isActive { lostFocus = true }
        post(.mouseMoved, at: p)
        for n in 1...count {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                eventNumber += 1
                if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber,
                                              clickCount: n, pressure: type == .leftMouseDown ? 1 : 0) {
                    NSApp.postEvent(e, atStart: false)
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    static func childRowsStep(_ model: AppModel) async {
        let breakMode = ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil
        let store = model.store
        let priorScope = model.scope
        var frame = window.frame
        frame.size = NSSize(width: 1500, height: 900)
        window.setFrame(frame, display: true)
        window.makeKeyAndOrderFront(nil)

        let project = store.createProject(name: "kids.fixture")
        let parent = store.create(title: "kids.P", project: project)
        let loose = store.create(title: "kids.T", project: project)
        let withKids = store.create(title: "kids.Q", project: project)
        let c1 = store.addSubtask(parent.id, title: "kids.c1")!
        let c2 = store.addSubtask(parent.id, title: "kids.c2")!
        let q1 = store.addSubtask(withKids.id, title: "kids.q1")!
        let label = store.label(named: "kids.label")
        store.update(c1.id) {
            $0.dueDay = Day.today() + 2
            $0.priorityRaw = KPriority.high.rawValue
            $0.effortRaw = KEffort.m.rawValue
            $0.notes = ContextLink(kind: .web, reference: "https://example.com/kids", displayName: "example.com").appending(to: "A note")
        }
        store.addLabel(label, to: c1.id)
        model.didMutate()
        model.scope = .project(project.id)
        model.searchText = ""
        model.selectedTaskID = nil
        model.inspectedSubtaskID = nil
        try? await Task.sleep(for: .milliseconds(800))
        await expandAll()
        defer {
            for id in [parent.id, loose.id, withKids.id] { store.softDelete(id) }
            model.inspectedSubtaskID = nil
            model.selectedTaskID = nil
            model.scope = priorScope
            model.didMutate()
        }

        // MARK: marks, one line
        let names = ["subrow.due.kids.c1", "subtask.badge.priority", "subrow.effort.kids.c1", "subrow.labels.kids.c1",
                     "subrow.links.kids.c1", "subrow.notes.kids.c1", "list.subtask.info.\(c1.id.uuidString)"]
        let missing = names.filter { UITestAnchors.frames[$0] == nil }
        let rowHeight = UITestAnchors.frames["subrow.kids.c1"]?.height ?? 999
        record("child row shows due, priority, effort, label chip, link and notes indicators and the info button, on one line",
               missing.isEmpty && rowHeight <= Metrics.rowHeightDense * 1.5,
               "missing=\(missing) height=\(Int(rowHeight)) limit=\(Int(Metrics.rowHeightDense * 1.5))")
        let plain = UITestAnchors.frames["subrow.kids.c2"]?.height ?? 999
        record("a child without marks is the same height as one with every mark", abs(plain - rowHeight) < 1, "plain=\(plain) full=\(rowHeight)")

        // MARK: info button
        let infoClicked = await click("list.subtask.info.\(c1.id.uuidString)")
        try? await Task.sleep(for: .milliseconds(600))
        record("info button opens the child's details (parent selected, child inspected, breadcrumb back shown)",
               infoClicked && model.selectedTaskID == parent.id && model.inspectedSubtaskID == c1.id && UITestAnchors.frames["inspector.child.back"] != nil,
               "clicked=\(infoClicked) selected=\(model.selectedTaskID == parent.id) inspected=\(model.inspectedSubtaskID == c1.id)")

        // MARK: double-click (starts from the parent selected, the state the proven row-click steps use)
        model.selectedTaskID = parent.id
        model.inspectedSubtaskID = nil
        try? await Task.sleep(for: .milliseconds(700))
        await expandAll()
        if let p = point("subrow.kids.c2", xFraction: 0.35) {
            let hit = window.contentView?.hitTest(window.contentView!.convert(p, from: nil))
            diagnostics.append("kids double-click: win=(\(Int(p.x)),\(Int(p.y))) frame=\(String(describing: UITestAnchors.frames["subrow.kids.c2"])) hit=\(hit.map { String(describing: type(of: $0)) } ?? "nil") active=\(NSApp.isActive)")
            await multiClick(p, count: 2)
        } else {
            diagnostics.append("kids double-click: no anchor subrow.kids.c2")
        }
        try? await Task.sleep(for: .milliseconds(700))
        diagnostics.append("kids double-click after: focus=\(SubtaskFocus.current(in: model) == c2.id) fr=\(window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil") sel=\(model.selectedTaskID == parent.id) insp=\(String(describing: model.inspectedSubtaskID))")
        record("double-click on a child row opens its details",
               model.selectedTaskID == parent.id && model.inspectedSubtaskID == c2.id,
               "selected=\(model.selectedTaskID == parent.id) inspected=\(model.inspectedSubtaskID == c2.id)")

        // MARK: Return on the focused child row
        model.inspectedSubtaskID = nil
        try? await Task.sleep(for: .milliseconds(500))
        if let p = point("subrow.kids.c1", xFraction: 0.35) { await clickPoint(p) }
        try? await Task.sleep(for: .milliseconds(900))   // past the double-click interval
        let openedByClick = model.inspectedSubtaskID != nil
        diagnostics.append("kids return before: focus=\(SubtaskFocus.current(in: model) == c1.id) fr=\(window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil") sel=\(model.selectedTaskID == parent.id)")
        key("\r", keyCode: 36)
        try? await Task.sleep(for: .milliseconds(600))
        record("Return on a focused child row opens its details (a single click alone does not)",
               !openedByClick && model.inspectedSubtaskID == c1.id,
               "openedByClick=\(openedByClick) inspected=\(model.inspectedSubtaskID == c1.id)")
        model.inspectedSubtaskID = nil
        model.selectedTaskID = nil
        try? await Task.sleep(for: .milliseconds(400))
        await expandAll()

        // MARK: drop onto a child row: sibling under the same parent, right after it
        guard let overlay = ListDropOverlayView.live, let controller = overlay.controller else {
            record("child drops: the drop overlay is mounted", false, "no live overlay")
            return
        }
        let tasks: [String: KTask] = ["T": loose, "Q": withKids]
        func kids(_ t: KTask) -> [String] { store.task(t.id)?.orderedChildren.map(\.title) ?? [] }
        var before = snapshot(model, project)
        var depth = store.undoDepth
        _ = await drag(model, internalTask("T", tasks), [DropStop(anchor: "subrow.kids.c1", y: 0.5, dwellMs: 150)], end: .hover)
        try? await Task.sleep(for: .milliseconds(800))
        let hint = controller.feedback?.hint
        _ = await finish(overlay, controller, model, internalTask("T", tasks), end: .drop)
        let moved = store.task(loose.id)
        record("task dropped onto a child row becomes its sibling right after it under the same parent, never a grandchild",
               hint == .nest && kids(parent) == (breakMode ? ["kids.c1", "kids.c2", "kids.T"] : ["kids.c1", "kids.T", "kids.c2"])
                   && moved?.parentID == parent.id && (moved?.orderedChildren.isEmpty ?? false) && store.undoDepth - depth == 1,
               "hint=\(String(describing: hint)) kids=\(kids(parent)) parentOK=\(moved?.parentID == parent.id) steps=\(store.undoDepth - depth)")
        store.undo(); model.didMutate(); await settle(); await expandAll()
        record("child drop: one undo restores the task and the order exactly", snapshot(model, project) == before, "")

        // MARK: a task with children dropped onto a child row: flatten, all siblings
        before = snapshot(model, project)
        depth = store.undoDepth
        _ = await drag(model, internalTask("Q", tasks), [DropStop(anchor: "subrow.kids.c2", y: 0.5, dwellMs: 150)], end: .hover)
        try? await Task.sleep(for: .milliseconds(800))
        _ = await finish(overlay, controller, model, internalTask("Q", tasks), end: .drop)
        record("task with children dropped onto a child row: it and its children become siblings under that parent (one level)",
               kids(parent) == ["kids.c1", "kids.c2", "kids.Q", "kids.q1"] && (store.task(withKids.id)?.orderedChildren.isEmpty ?? false)
                   && store.task(q1.id)?.parentID == parent.id && store.undoDepth - depth == 1,
               "kids=\(kids(parent)) steps=\(store.undoDepth - depth)")
        store.undo(); model.didMutate(); await settle(); await expandAll()
        record("flatten drop: undo gives the task and its child back exactly", snapshot(model, project) == before && kids(withKids) == ["kids.q1"], "")

        // MARK: label filter: the parent row is listed and the labelled child is marked under it
        NotificationCenter.default.post(name: .kronosExpandAllSubtasks, object: false)
        await settle()
        let priorOptions = model.options(for: model.scope)
        LabelMenu.filterByLabel(label.id, model: model)
        await settle(); await settle()
        let filtered = ListContext(model: model).rows.map(\.title)
        let marked = UITestAnchors.frames["subrow.labelmatch.kids.c1"] != nil
        let wrongMark = UITestAnchors.frames["subrow.labelmatch.kids.c2"] != nil
        record("label filter lists the parent of a labelled child once, opens it and marks only that child",
               filtered == ["kids.P"] && marked && !wrongMark,
               "rows=\(filtered) c1Marked=\(marked) c2Marked=\(wrongMark)")
        model.setOptions(priorOptions, for: model.scope)
        model.didMutate()
        await settle()

        // MARK: waits-on: a child is offered as "Parent › Child" and shows as such a chip
        let offered = store.waitsOnCandidates(for: loose.id, query: "kids.c1").map(\.waitsOnDisplayName)
        model.openDetails(taskID: loose.id)
        store.setWaitsOn(loose.id, [c1.id])
        model.didMutate()
        await settle(); await settle()
        let chip = UITestAnchors.frames["inspector.waitson.chip.kids.P › kids.c1"] != nil
        record("waits-on picker offers a child task as Parent › Child and the chosen child shows as that chip",
               offered == ["kids.P › kids.c1"] && chip && store.task(loose.id)?.waitsOn == [c1.id],
               "offered=\(offered) chip=\(chip)")
        store.setWaitsOn(loose.id, [])
        model.didMutate()

        // MARK: open by id (kronos://open, Spotlight, Dock) goes through the one details route
        model.scope = .inbox
        model.selectedTaskID = nil
        model.inspectedSubtaskID = nil
        await settle()
        let opened = model.openTaskByID(c2.id)
        await settle(); await settle()
        let back = UITestAnchors.frames["inspector.child.back"] != nil
        record("open by id on a child shows its parent's list, selects the parent and inspects the child",
               opened && model.scope == .project(project.id) && model.selectedTaskID == parent.id
                   && model.inspectedSubtaskID == c2.id && back,
               "opened=\(opened) selected=\(model.selectedTaskID == parent.id) inspected=\(model.inspectedSubtaskID == c2.id) back=\(back)")

        // MARK: palette task commands act on the task the inspector shows (the child in child mode)
        let commands = PaletteCommands.all(model: model)
        let parentPriority = store.task(parent.id)?.priority
        let depthBefore = store.undoDepth
        if let high = commands.first(where: { $0.id == "task.priority.high" }), high.isAvailable(model) { high.run(model) }
        await settle()
        let breakdownOffered = commands.first(where: { $0.id == "task.breakdown" })?.isAvailable(model) ?? true
        record("palette priority command in child mode sets the child's priority, not the parent's; no Break down for a child",
               store.task(c2.id)?.priority == .high && store.task(parent.id)?.priority == parentPriority
                   && store.undoDepth == depthBefore + 1 && !breakdownOffered,
               "child=\(String(describing: store.task(c2.id)?.priority)) parentSame=\(store.task(parent.id)?.priority == parentPriority) steps=\(store.undoDepth - depthBefore) breakdown=\(breakdownOffered)")
        store.undo(); model.didMutate()
        model.closeChildDetails()
    }
}
#endif
