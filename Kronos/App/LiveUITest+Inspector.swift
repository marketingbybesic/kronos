// Kronos/App/LiveUITest+Inspector.swift — live steps for the inspector's subtask mode, links
// section and steps list:
//  A. the ⓘ on every step row opens child mode in the normal inspector (breadcrumb, title, due, priority, notes,
//     links all present); focusing the title and going back without an edit pushes no undo step.
//  B. due and priority show as compact marks on the step row; each edit is ONE undo step; the
//     ⓘ on the middle list's subtask row opens the same mode.
//  C. links: add (the exact routine the "+" menu items call), never empty, never duplicated,
//     removed by the chip's own X; Cmd-V of a URL with the inspector focused (not a text field)
//     creates a web chip labelled with the host, and Cmd-V of plain text creates nothing.
//  D. Option-Down on a focused step reorders it, in ONE undo step.
// What a live run cannot press: the "+" menu's NSOpenPanel and the sheet's keyboard flow, and a
// real drag of a step row (AppKit owns the drag session) — those are in docs/the internal notes.
#if !RELEASE
import AppKit
import KronosCore

@MainActor
extension LiveUITest {

    private static func inspSettle(_ ms: Int = 500) async { try? await Task.sleep(for: .milliseconds(ms)) }

    private static func inspUndo(_ model: AppModel) async {
        if let item = undoMenuItem(), let menu = item.menu { menu.performActionForItem(at: menu.index(of: item)) }
        await inspSettle(400)
    }

    static func inspectorSubtaskStep(_ model: AppModel) async {
        let store = model.store
        var frame = window.frame
        frame.size = NSSize(width: 1500, height: 900)
        window.setFrame(frame, display: true)
        await inspSettle(700)
        window.makeKeyAndOrderFront(nil)

        let parentTitle = "L4 inspector parent"
        let parent = store.create(title: parentTitle, notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
        for title in ["L4 step one", "L4 step two", "L4 step three"] { store.addSubtask(parent.id, title: title) }
        model.didMutate()
        func steps() -> [KTask] { store.task(parent.id)?.orderedSubtasks ?? [] }
        func links(_ target: AttachmentTarget) -> [ContextLink] { ContextLink.findAll(in: LinkEditing.notes(of: target, model: model)) }
        model.scope = .all
        model.searchText = ""
        model.inspectedSubtaskID = nil
        await inspSettle(500)   // the shell clears the selection when the scope changes: select after that has run
        model.selectedTaskID = parent.id
        await inspSettle(800)
        defer { store.softDelete(parent.id); model.inspectedSubtaskID = nil; model.didMutate() }

        // A. ⓘ opens subtask mode.
        let infoPresent = (0..<3).allSatisfy { UITestAnchors.frames["inspector.step.info.\($0)"] != nil }
        record("inspector steps: every step row has an ⓘ button", infoPresent,
               "anchors=\((0..<3).map { UITestAnchors.frames["inspector.step.info.\($0)"] != nil })")
        let second = steps()[1]
        let stepsShownForParent = UITestAnchors.frames["inspector.steps"] != nil
        let clicked = await click("inspector.step.info.1")
        await inspSettle(600)
        // Child mode is the normal inspector: the same sections, the breadcrumb, no steps section.
        let parts = ["inspector.child.back", "inspector.title", "inspector.due", "inspector.priority", "inspector.effort",
                     "inspector.links.add", "inspector.project.inherited"]
        let missing = parts.filter { UITestAnchors.frames[$0] == nil }
        let stepsAbsent = UITestAnchors.frames["inspector.steps"] == nil
        record("child-inspector-open: ⓘ opens the normal inspector in child mode (breadcrumb, title, effort, due, priority, links, inherited project) with no steps section",
               stepsShownForParent && clicked && model.inspectedSubtaskID == second.id && missing.isEmpty && stepsAbsent,
               "parentShowedSteps=\(stepsShownForParent) clicked=\(clicked) inspected=\(model.inspectedSubtaskID == second.id) missing=\(missing) stepsAbsent=\(stepsAbsent)")
        // Focus the title and leave without an edit: nothing may be written.
        let depthBeforeBlur = store.undoDepth
        _ = await click("inspector.title"); await inspSettle(300)
        let back = await click("inspector.child.back"); await inspSettle(600)
        record("child-inspector-back: breadcrumb returns to the parent; an untouched title pushes no undo step",
               back && model.inspectedSubtaskID == nil && store.undoDepth == depthBeforeBlur && UITestAnchors.frames["inspector.step.info.0"] != nil
                 && UITestAnchors.frames["inspector.steps"] != nil,
               "back=\(back) inspectedNil=\(model.inspectedSubtaskID == nil) depth \(depthBeforeBlur)->\(store.undoDepth)")

        // Edits on a child use the task setters: effort and a label, one undo step each; Esc returns to the parent.
        _ = model.openDetails(taskID: second.id); await inspSettle(600)
        let routed = model.selectedTaskID == parent.id && model.inspectedSubtaskID == second.id
        // Creating a label is its own undo step: make it before the two edits under test.
        let label = store.label(named: "l4-child-label")
        store.setEffort(second.id, .l); model.didMutate()
        store.addLabel(label, to: second.id); model.didMutate()
        await inspSettle(500)
        let edited = store.task(second.id)
        let editedOK = edited?.effort == .l && (edited?.labels ?? []).contains { $0.id == label.id }
        // A task is a class: read the values after EACH undo, a held reference shows the latest state.
        await inspUndo(model)
        let labelGoneAfterFirstUndo = !(store.task(second.id)?.labels ?? []).contains { $0.id == label.id }
        let effortAfterFirstUndo = store.task(second.id)?.effort
        await inspUndo(model)
        let effortAfterSecondUndo = store.task(second.id)?.effort
        record("child-inspector-edit: openDetails routes a child to parent + child mode; effort and label edits on the child each undo in one step",
               routed && editedOK && labelGoneAfterFirstUndo && effortAfterFirstUndo == .l && effortAfterSecondUndo == KEffort.none,
               "routed=\(routed) edited=\(editedOK) labelUndone=\(labelGoneAfterFirstUndo) effortAfterFirst=\(String(describing: effortAfterFirstUndo)) effortAfterSecond=\(String(describing: effortAfterSecondUndo))")
        window.makeKeyAndOrderFront(nil)
        key("\u{1B}", keyCode: 53); await inspSettle(500)
        record("child-inspector-esc: Esc in child mode goes back to the parent",
               model.inspectedSubtaskID == nil && model.selectedTaskID == parent.id && UITestAnchors.frames["inspector.steps"] != nil,
               "inspected=\(String(describing: model.inspectedSubtaskID)) selectedParent=\(model.selectedTaskID == parent.id) steps=\(UITestAnchors.frames["inspector.steps"] != nil)")

        // B. due + priority marks, one undo step each.
        let first = steps()[0]
        store.setSubtaskDueDay(first.id, Day.today() + 1); model.didMutate()
        store.setSubtaskPriority(first.id, .high); model.didMutate()
        await inspSettle(600)
        record("subtask-badges: a step with due and priority shows both marks on its row",
               UITestAnchors.frames["subtask.badge.due"] != nil && UITestAnchors.frames["subtask.badge.priority"] != nil,
               "due=\(UITestAnchors.frames["subtask.badge.due"] != nil) priority=\(UITestAnchors.frames["subtask.badge.priority"] != nil)")
        await inspUndo(model)
        // A task is a class: read the values NOW, a held reference would show the state after the second undo.
        let afterOne = steps().first { $0.id == first.id }.map { (prio: $0.priority, due: $0.dueDay) }
        await inspUndo(model)
        let afterTwoDue = steps().first { $0.id == first.id }?.dueDay
        record("subtask-undo: each field edit is its own undo step (priority first, then due)",
               afterOne?.prio == KPriority.none && afterOne?.due != nil && afterTwoDue == nil,
               "afterOne prio=\(String(describing: afterOne?.prio)) due=\(String(describing: afterOne?.due)) afterTwo due=\(String(describing: afterTwoDue))")

        // The ⓘ in the middle list (rows are expanded the same way the E key does it).
        model.searchText = parentTitle   // narrow the lazy list so this parent's row is rendered
        await inspSettle(600)
        NotificationCenter.default.post(name: .kronosExpandAllSubtasks, object: true)
        await inspSettle(700)
        let listAnchor = "list.subtask.info." + second.id.uuidString
        let listClicked = await click(listAnchor)
        await inspSettle(600)
        record("subtask-inspector-open (list): ⓘ on the middle list's subtask row opens subtask mode",
               listClicked && model.inspectedSubtaskID == second.id && model.selectedTaskID == parent.id,
               "anchor=\(UITestAnchors.frames[listAnchor] != nil) inspected=\(model.inspectedSubtaskID == second.id) selected=\(model.selectedTaskID == parent.id)")
        model.inspectedSubtaskID = nil
        NotificationCenter.default.post(name: .kronosExpandAllSubtasks, object: false)
        model.searchText = ""
        await inspSettle(500)

        // C. links.
        let target = AttachmentTarget.task(parent.id)
        let web = LinkInput.web("example.com/l4-links")
        let added = web.map { LinkEditing.add(LinkEditing.webLink($0), to: target, model: model) } ?? false
        await inspSettle(500)
        let depthAfterAdd = store.undoDepth
        let duplicate = web.map { LinkEditing.add(LinkEditing.webLink($0), to: target, model: model) } ?? true
        let empty = LinkEditing.add(ContextLink(kind: .web, reference: "  ", displayName: "x"), to: target, model: model)
        record("links-add: a web link attaches with the host as its label; duplicates and empty references are refused without an undo step",
               added && links(target).count == 1 && links(target).first?.displayName == "example.com" && !duplicate && !empty
                 && store.undoDepth == depthAfterAdd && UITestAnchors.frames["inspector.contextlink.chip"] != nil,
               "added=\(added) links=\(links(target).map(\.displayName)) dup=\(duplicate) empty=\(empty) depth=\(depthAfterAdd)->\(store.undoDepth) chip=\(UITestAnchors.frames["inspector.contextlink.chip"] != nil)")
        let removed = await click("inspector.contextlink.remove"); await inspSettle(500)
        record("links-remove: the chip's X removes only that link", removed && links(target).isEmpty, "clicked=\(removed) left=\(links(target).count)")

        // Cmd-V with the inspector (a step row) focused, not a text field. Plain text first: no chip.
        let saved = NSPasteboard.general.string(forType: .string)
        defer { NSPasteboard.general.clearContents(); if let saved { NSPasteboard.general.setString(saved, forType: .string) } }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString("buy milk and eggs", forType: .string)
        _ = await click("inspector.step.row.1", xFraction: 0.5); await inspSettle(300)
        key("v", modifiers: .command, keyCode: 9); await inspSettle(500)
        let noChipForText = links(target).isEmpty
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString("https://example.com/l4-paste", forType: .string)
        key("v", modifiers: .command, keyCode: 9); await inspSettle(600)
        let pasted = links(target)
        record("links-paste-url: Cmd-V of a URL creates a web chip labelled with the host; plain text creates none",
               noChipForText && pasted.count == 1 && pasted.first?.kind == .web && pasted.first?.reference == "https://example.com/l4-paste"
                 && pasted.first?.displayName == (ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil ? "WRONG" : "example.com"),
               "textMadeChip=\(!noChipForText) pasted=\(pasted.map { "\($0.kind.rawValue)|\($0.displayName)|\($0.reference)" })")

        // Same section on a subtask: the add routine writes the subtask's own notes.
        let subTarget = AttachmentTarget.subtask(steps()[2])
        let subAdded = LinkEditing.add(LinkEditing.webLink(LinkInput.web("https://example.org/sub")!), to: subTarget, model: model)
        record("links-subtask: the same routine attaches to a subtask, not its parent",
               subAdded && links(subTarget).count == 1 && links(target).count == 1,
               "sub=\(links(subTarget).map(\.displayName)) parent=\(links(target).count)")

        // D. keyboard reorder, one undo step.
        _ = await click("inspector.step.row.0", xFraction: 0.5); await inspSettle(300)
        let before = steps().map(\.title)
        key("\u{F701}", modifiers: [.option, .numericPad, .function], keyCode: 125); await inspSettle(500)
        let after = steps().map(\.title)
        await inspUndo(model)
        let undone = steps().map(\.title)
        record("steps-keyboard-reorder: Option-Down moves the focused step down one place; one Undo restores",
               before == ["L4 step one", "L4 step two", "L4 step three"] && after == ["L4 step two", "L4 step one", "L4 step three"] && undone == before,
               "before=\(before) after=\(after) undone=\(undone)")
        // The drag path's decision logic is covered by scripts/linkinput-selftest.swift; a real drag
        // session cannot be posted from here.
    }
}
#endif
