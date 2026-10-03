// Kronos/App/LiveUITest+ChildLinks.swift — in the inspector's child mode every action targets the
// shown child, never its parent. Links a note (through the real "Link Apple note" button and the
// picker sheet) and a web link while a child is shown, then asserts both landed on the child and
// the parent's notes are byte-identical to before.
#if !RELEASE
import AppKit
import KronosCore

@MainActor
extension LiveUITest {
    static func childModeLinksTargetChild(_ model: AppModel) async {
        let store = model.store
        let mainWindow = window!
        func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
        model.notes = NoteLinkTestFixtures.bridge()
        var frame = mainWindow.frame
        frame.size = NSSize(width: 1500, height: 900)
        mainWindow.setFrame(frame, display: true)
        await settle(300)

        let parent = store.create(title: "L6 link parent", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
        guard let child = store.addSubtask(parent.id, title: "L6 link child") else {
            record("child-mode links: fixture child exists", false, ""); return
        }
        model.didMutate()
        defer { store.softDelete(parent.id); model.inspectedSubtaskID = nil; model.didMutate() }
        model.searchText = ""
        model.scope = .all
        model.inspectedSubtaskID = nil
        await settle(500)
        _ = model.openDetails(taskID: child.id)
        await settle(800)
        let parentNotesBefore = store.task(parent.id)?.notes ?? ""
        record("child-mode links: the shown task is the child", model.inspectedTaskID == child.id && model.selectedTaskID == parent.id,
               "inspected=\(model.inspectedTaskID == child.id) selected=\(model.selectedTaskID == parent.id)")

        // Web link while the child is shown.
        if let web = LinkInput.web("example.com/child-mode") {
            LinkEditing.add(LinkEditing.webLink(web), to: .task(model.inspectedTaskID ?? parent.id), model: model)
        }
        await settle(300)

        // Apple note through the real button and picker.
        let clicked = await click("inspector.notes.notelink.add")
        await settle(1800)
        var picked = false
        if let sheet = NSApp.windows.first(where: { $0.isVisible && $0 !== mainWindow && $0.canBecomeKey }) {
            window = sheet
            await settle(300)
            _ = await click("notespicker.folder.Kronos"); await settle(400)
            picked = await click("notespicker.row.Acme kickoff recap")
            await settle(500)
            window = mainWindow
        }

        let childNotes = store.task(child.id)?.notes ?? ""
        let parentNotesAfter = store.task(parent.id)?.notes ?? ""
        let noteOnChild = NoteLink.find(in: childNotes) == "n1"
        let webOnChild = ContextLink.findAll(in: childNotes).contains { $0.kind == .web }
        record("child-mode links: note and web link land on the child, the parent is unchanged",
               clicked && picked && noteOnChild && webOnChild && parentNotesAfter == parentNotesBefore
                   && NoteLink.find(in: parentNotesAfter) == nil,
               "clicked=\(clicked) picked=\(picked) noteOnChild=\(noteOnChild) webOnChild=\(webOnChild) parentUnchanged=\(parentNotesAfter == parentNotesBefore)")
    }
}
#endif
