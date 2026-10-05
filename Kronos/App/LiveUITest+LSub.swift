// Kronos/App/LiveUITest+LSub.swift — live proof that a child row's title renames in place: double-click
// the title, type, Return commits (one undo step) and the details do NOT open; Esc cancels; a blur with
// no change writes nothing. Real mouse and key events posted to the window.
// Compiled only outside Release, like every live step.
#if !RELEASE
import AppKit
import KronosCore

@MainActor
extension LiveUITest {
    static func lSubSteps(_ model: AppModel) async {
        let breakMode = ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil
        let store = model.store
        let priorScope = model.scope
        var frame = window.frame
        frame.size = NSSize(width: 1500, height: 900)
        window.setFrame(frame, display: true)
        window.makeKeyAndOrderFront(nil)

        let project = store.createProject(name: "lsub.fixture")
        let parent = store.create(title: "lsub.P", project: project)
        let child = store.addSubtask(parent.id, title: "lsub.old")!
        model.didMutate()
        model.scope = .project(project.id)
        model.searchText = ""
        model.selectedTaskID = nil
        model.inspectedSubtaskID = nil
        try? await Task.sleep(for: .milliseconds(800))
        await expandAll()
        defer {
            store.softDelete(parent.id)
            model.inspectedSubtaskID = nil
            model.selectedTaskID = nil
            model.scope = priorScope
            model.didMutate()
        }

        func title() -> String? { store.task(child.id)?.title }
        func editing() -> Bool { UITestAnchors.frames["subrow.title.edit"] != nil }

        // MARK: rename with Return
        let depth = store.undoDepth
        if let p = point("subrow.title.lsub.old", xFraction: 0.3) {
            await multiClick(p, count: 2)
        }
        let opened = await waitUntil(timeout: 3) { editing() }
        let detailsOpenedByTitle = model.inspectedSubtaskID != nil
        record("double-click on a child title turns it into an inline field, and the details stay closed",
               opened && !detailsOpenedByTitle, "field=\(opened) inspected=\(String(describing: model.inspectedSubtaskID))")
        (window.firstResponder as? NSTextView)?.selectAll(nil)
        await typeText("lsub.new")
        if breakMode { key("\u{1B}", keyCode: 53) } else { key("\r", keyCode: 36) }
        await settle(700)
        record("Return commits the typed name to the store as one undo step, the field closes, details did not open",
               title() == "lsub.new" && !editing() && model.inspectedSubtaskID == nil && store.undoDepth - depth == 1,
               "title=\(title() ?? "nil") editing=\(editing()) inspected=\(String(describing: model.inspectedSubtaskID)) steps=\(store.undoDepth - depth)")
        store.undo(); model.didMutate()
        await settle(500)
        record("undo restores the old child title in one step", title() == "lsub.old" && store.undoDepth == depth,
               "title=\(title() ?? "nil") depth=\(store.undoDepth - depth)")
        await expandAll()

        // MARK: Esc cancels
        if let p = point("subrow.title.lsub.old", xFraction: 0.3) { await multiClick(p, count: 2) }
        _ = await waitUntil(timeout: 3) { editing() }
        (window.firstResponder as? NSTextView)?.selectAll(nil)
        await typeText("lsub.discard")
        key("\u{1B}", keyCode: 53)
        await settle(700)
        record("Esc cancels the rename: title unchanged, no undo step, field closed",
               title() == "lsub.old" && !editing() && store.undoDepth == depth,
               "title=\(title() ?? "nil") editing=\(editing()) steps=\(store.undoDepth - depth)")

        // MARK: blur without change writes nothing
        if let p = point("subrow.title.lsub.old", xFraction: 0.3) { await multiClick(p, count: 2) }
        _ = await waitUntil(timeout: 3) { editing() }
        key("\r", keyCode: 36)
        await settle(600)
        record("Return on an unchanged title pushes no undo step",
               title() == "lsub.old" && !editing() && store.undoDepth == depth,
               "title=\(title() ?? "nil") steps=\(store.undoDepth - depth)")

        // MARK: double-click outside the title still opens the details
        await expandAll()
        model.selectedTaskID = parent.id
        model.inspectedSubtaskID = nil
        await settle(600)
        let trailing = point("subrow.lsub.old", xFraction: 0.7)
        diagnostics.append("lsub trailing: point=\(String(describing: trailing)) frame=\(String(describing: UITestAnchors.frames["subrow.lsub.old"]))")
        if let p = trailing { await multiClick(p, count: 2) }
        await settle(700)
        record("double-click on the trailing part of a child row still opens its details",
               model.selectedTaskID == parent.id && model.inspectedSubtaskID == child.id,
               "selected=\(model.selectedTaskID == parent.id) inspected=\(String(describing: model.inspectedSubtaskID))")
    }
}
#endif
