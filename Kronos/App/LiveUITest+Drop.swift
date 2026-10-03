// Kronos/App/LiveUITest+Drop.swift — live proof of the list's drag-and-drop engine, in process.
// No OS drag: the REAL overlay (ListDropOverlayView, the AppKit drop destination mounted over the
// list) receives a scripted NSDraggingInfo whose pasteboard is a REAL NSPasteboard of its own
// (a named one, never the person's clipboard or the system drag pasteboard) and whose locations
// are read off the rows' own anchors. Everything after that is the production path: payload
// reader, resolver, the 0.6 s Timer, indicators, commit, undo pill. What a script cannot prove is
// the OS handing Kronos a drag from Mail, Finder or Notes: that is on the person's hand-test list.
// Compiled only outside Release, like every live step.
#if !RELEASE
import AppKit
import SQLite3
import KronosCore

@MainActor
extension LiveUITest {
    enum DropEnd { case drop, cancel, hover }

    struct DropStop {
        let anchor: String
        let y: CGFloat          // 0 = top of the row, 1 = bottom
        let dwellMs: Int
    }

    struct Snapshot: Equatable {
        var lines: [String]
    }

    // MARK: Entry

    static func dropStep(_ model: AppModel) async {
        let breakMode = ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil
        let store = model.store
        let mainWindow = window!
        let priorScope = model.scope
        let priorNotes = model.notes
        let priorSubject = ListDropController.mailSubject
        defer { ListDropController.mailSubject = priorSubject; model.notes = priorNotes }

        var frame = mainWindow.frame
        frame.size = NSSize(width: 1500, height: 900)
        mainWindow.setFrame(frame, display: true)

        // A project of its own, so the list holds exactly these tasks.
        let project = store.createProject(name: "dnd.fixture")
        var t: [String: KTask] = [:]
        for n in 1...5 { let name = "dnd.T\(n)"; t["T\(n)"] = store.create(title: name, project: project) }
        let (stepOne, stepTwo) = ("dnd.S1", "dnd.S2")
        let s1 = store.addSubtask(t["T3"]!.id, title: stepOne)!
        let s2 = store.addSubtask(t["T3"]!.id, title: stepTwo)!
        s1.isDone = true
        s1.dueDay = Day.today() + 3
        s1.priorityRaw = 2
        model.didMutate()
        model.scope = .project(project.id)
        try? await Task.sleep(for: .milliseconds(700))
        await expandAll()

        guard let overlay = ListDropOverlayView.live, let controller = overlay.controller else {
            record("drop overlay is mounted over the list", false, "no live overlay")
            model.scope = priorScope
            return
        }
        let rowsRealised = controller.rows.count
        record("drop overlay is mounted and the rows report their frames", rowsRealised >= 7,
               "rows reported=\(rowsRealised) (5 tasks + 2 steps expected)")

        // MARK: invisible to the mouse, registered for every source
        ListDropOverlayView.forceDragHitTesting = false
        let probe = windowPoint("row.dnd.T1", y: 0.5) ?? .zero
        let hitWithoutDrag = mainWindow.contentView?.hitTest(mainWindow.contentView!.convert(probe, from: nil))
        ListDropOverlayView.forceDragHitTesting = true
        let overlayPoint = overlay.superview?.convert(probe, from: nil) ?? .zero
        let hitDuringDrag = overlay.hitTest(overlayPoint)
        ListDropOverlayView.forceDragHitTesting = false
        record("overlay lets clicks through and answers only while a drag is live",
               hitWithoutDrag !== overlay && !(hitWithoutDrag is ListDropOverlayView) && hitDuringDrag === overlay,
               "withoutDrag=\(hitWithoutDrag.map { String(describing: type(of: $0)) } ?? "nil") duringDrag=\(hitDuringDrag === overlay)")
        let registered = Set(overlay.registeredDraggedTypes.map(\.rawValue))
        record("overlay registers Notes, Mail, Finder and text types",
               ["com.apple.notes.note", "public.composite-content", "public.file-url", "public.url", "public.utf8-plain-text"].allSatisfy(registered.contains),
               "registered=\(registered.count)")

        // MARK: 1. reorder with the insertion line
        var before = snapshot(model, project)
        var depth = store.undoDepth
        var ok = await drag(model, internalTask("T4", t), [DropStop(anchor: "row.dnd.T1", y: 0.1, dwellMs: 200)], end: .hover)
        let lineFrame = UITestAnchors.frames["drop.line"]
        let t1Row = UITestAnchors.frames["row.dnd.T1"]
        let lineOK = lineFrame.map { abs($0.height - 2) < 0.6 && abs($0.midY - (t1Row?.minY ?? -99)) < 2.5 } ?? false
        record("reorder drag: accent insertion line, 2 pt, at the top edge of the target row", ok.accepted && lineOK,
               "line=\(lineFrame.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "none") rowTop=\(t1Row.map { Int($0.minY) } ?? -1)")
        _ = await drag(model, internalTask("T4", t), [DropStop(anchor: "row.dnd.T1", y: 0.1, dwellMs: 60)], end: .drop)
        var order = titles(model, project)
        record("reorder drag: the dragged task lands before the target",
               order == (breakMode ? ["dnd.T1", "dnd.T4", "dnd.T2", "dnd.T3", "dnd.T5"] : ["dnd.T4", "dnd.T1", "dnd.T2", "dnd.T3", "dnd.T5"]),
               "order=\(order)")
        record("reorder drag: one undo step and the undo pill",
               store.undoDepth - depth == 1 && UndoToastCenter.shared.current != nil,
               "steps=\(store.undoDepth - depth) pill=\(UndoToastCenter.shared.current?.message ?? "none")")
        store.undo(); model.didMutate(); await settle(); await expandAll()
        record("reorder drag: undo restores every sortIndex exactly", snapshot(model, project) == before, "")

        // Dropped where it already is: nothing pushed.
        before = snapshot(model, project)
        depth = store.undoDepth
        _ = await drag(model, internalTask("T2", t), [DropStop(anchor: "row.dnd.T3", y: 0.1, dwellMs: 60)], end: .drop)
        record("reorder drag onto its own place changes nothing and pushes no undo step",
               store.undoDepth == depth && snapshot(model, project) == before, "steps=\(store.undoDepth - depth)")

        // MARK: 2. nest needs the hold
        before = snapshot(model, project)
        depth = store.undoDepth
        ok = await drag(model, internalTask("T4", t), [DropStop(anchor: "row.dnd.T2", y: 0.5, dwellMs: 150)], end: .drop)
        record("centre drop before the 0.6 s hold does nothing",
               !ok.dropped && store.undoDepth == depth && snapshot(model, project) == before,
               "dropped=\(ok.dropped) steps=\(store.undoDepth - depth)")

        ok = await drag(model, internalTask("T4", t), [DropStop(anchor: "row.dnd.T2", y: 0.5, dwellMs: 150)], end: .hover)
        let beforeHold = controller.feedback?.hint
        try? await Task.sleep(for: .milliseconds(650))   // the real Timer fires, nobody moves the pointer
        try? await Task.sleep(for: .milliseconds(150))
        let afterHold = controller.feedback?.hint
        let outline = UITestAnchors.frames["drop.outline"], ghost = UITestAnchors.frames["drop.ghost"], hint = UITestAnchors.frames["drop.hint"]
        record("nest: nothing before the hold; after 0.6 s of rest the outline, indented ghost line and hint appear",
               beforeHold == nil && afterHold == .nest && outline != nil && ghost != nil && hint != nil,
               "before=\(String(describing: beforeHold)) after=\(String(describing: afterHold)) outline=\(outline != nil) ghost=\(ghost != nil) hint=\(hint != nil)")
        let hintText = String(localized: "list.drop.hint.nest")
        record("nest hint is the localised 'Becomes subtask'", hintText == "Becomes subtask" || hintText == "Postaje podzadatak", hintText)
        _ = await finish(overlay, controller, model, internalTask("T4", t), end: .drop)
        record("nest: the task becomes a subtask of the target",
               store.task(t["T4"]!.id)?.parentID == t["T2"]!.id && (store.task(t["T2"]!.id)?.orderedSubtasks.map(\.title) ?? []) == ["dnd.T4"],
               "t4Parent=\(String(describing: store.task(t["T4"]!.id)?.parentID)) t2Steps=\(store.task(t["T2"]!.id)?.orderedSubtasks.map(\.title) ?? [])")
        record("nest: one undo step and the undo pill", store.undoDepth - depth == 1 && UndoToastCenter.shared.current != nil, "steps=\(store.undoDepth - depth)")
        store.undo(); model.didMutate(); await settle(); await expandAll()
        record("nest: undo restores the task with its id and sortIndex", snapshot(model, project) == before, "")

        // MARK: 3. flatten
        before = snapshot(model, project)
        depth = store.undoDepth
        _ = await drag(model, internalTask("T3", t), [DropStop(anchor: "row.dnd.T1", y: 0.5, dwellMs: 150)], end: .hover)
        try? await Task.sleep(for: .milliseconds(800))
        _ = await finish(overlay, controller, model, internalTask("T3", t), end: .drop)
        let t1Steps = store.task(t["T1"]!.id)?.orderedSubtasks.map(\.title) ?? []
        record("nest with subtasks: they follow it, in order, one level under the new parent",
               t1Steps == ["dnd.T3", "dnd.S1", "dnd.S2"] && store.task(t["T3"]!.id)?.parentID == t["T1"]!.id && store.undoDepth - depth == 1,
               "t1Steps=\(t1Steps) steps=\(store.undoDepth - depth)")
        store.undo(); model.didMutate(); await settle(); await expandAll()
        record("flatten: undo gives back the task and both steps exactly", snapshot(model, project) == before, "")

        // MARK: 4. repeating and calendar tasks nest like any task (a subtask keeps both)
        for (label, mutate, reset, kept) in [
            ("recurring task", { (k: KTask) in k.recurrenceRule = "FREQ=DAILY" }, { (k: KTask) in k.recurrenceRule = nil },
             { (k: KTask?) in k?.recurrenceRule == "FREQ=DAILY" }),
            ("task with a calendar event", { (k: KTask) in k.calendarEventID = "event-dnd" }, { (k: KTask) in k.calendarEventID = nil },
             { (k: KTask?) in k?.calendarEventID == "event-dnd" }),
        ] as [(String, (KTask) -> Void, (KTask) -> Void, (KTask?) -> Bool)] {
            store.update(t["T5"]!.id, mutate); model.didMutate(); await settle()
            before = snapshot(model, project)
            depth = store.undoDepth
            _ = await drag(model, internalTask("T5", t), [DropStop(anchor: "row.dnd.T1", y: 0.5, dwellMs: 150)], end: .hover)
            try? await Task.sleep(for: .milliseconds(800))
            let hint = controller.feedback?.hint
            let dropped = await finish(overlay, controller, model, internalTask("T5", t), end: .drop)
            let nested = store.task(t["T5"]!.id)
            record("nest (\(label)): becomes a subtask and keeps the field, one undo step",
                   hint == .nest && dropped && nested?.parentID == t["T1"]!.id && kept(nested) && store.undoDepth - depth == 1,
                   "hint=\(String(describing: hint)) dropped=\(dropped) parent=\(String(describing: nested?.parentID)) steps=\(store.undoDepth - depth)")
            store.undo(); model.didMutate(); await settle(); await expandAll()
            record("nest (\(label)): undo restores exactly", snapshot(model, project) == before, "")
            store.update(t["T5"]!.id, reset); model.didMutate()
            await settle()
        }
        await expandAll()

        // MARK: 5. step reorder inside the same task (indented line)
        before = snapshot(model, project)
        depth = store.undoDepth
        ok = await drag(model, internalSubtask(s2, t["T3"]!), [DropStop(anchor: "subrow.dnd.S1", y: 0.1, dwellMs: 200)], end: .hover)
        let stepLine = UITestAnchors.frames["drop.line"], s1Row = UITestAnchors.frames["subrow.dnd.S1"], t3Row = UITestAnchors.frames["row.dnd.T3"]
        let indented = stepLine.map { l in (s1Row.map { l.minX >= $0.minX + ListDropController.subtaskIndent - 1 } ?? false) && l.minX > (t3Row?.minX ?? 0) + 20 } ?? false
        record("step drag: the insertion line is indented to the step level", ok.accepted && indented,
               "line=\(stepLine.map { "x=\(Int($0.minX))" } ?? "none") stepRow=\(s1Row.map { "x=\(Int($0.minX))" } ?? "none") indent=\(Int(ListDropController.subtaskIndent))")
        _ = await finish(overlay, controller, model, internalSubtask(s2, t["T3"]!), end: .drop)
        record("step drag: reorders within the same parent in one undo step",
               (store.task(t["T3"]!.id)?.orderedSubtasks.map(\.title) ?? []) == ["dnd.S2", "dnd.S1"] && store.undoDepth - depth == 1,
               "steps=\(store.task(t["T3"]!.id)?.orderedSubtasks.map(\.title) ?? []) undo=\(store.undoDepth - depth)")
        store.undo(); model.didMutate(); await settle(); await expandAll()
        record("step reorder: undo restores sortIndex exactly", snapshot(model, project) == before, "")

        // Dropped where it already is (S1 is directly before S2): nothing pushed.
        before = snapshot(model, project)
        depth = store.undoDepth
        _ = await drag(model, internalSubtask(s1, t["T3"]!), [DropStop(anchor: "subrow.dnd.S2", y: 0.1, dwellMs: 100)], end: .drop)
        record("step drag onto its own place changes nothing and pushes no undo step",
               store.undoDepth == depth && snapshot(model, project) == before, "steps=\(store.undoDepth - depth)")

        // MARK: 6. step out to level 0
        before = snapshot(model, project)
        depth = store.undoDepth
        _ = await drag(model, internalSubtask(s1, t["T3"]!), [DropStop(anchor: "row.dnd.T5", y: 0.1, dwellMs: 100)], end: .drop)
        let promoted = store.allTasks().first { $0.title == "dnd.S1" }
        let beforeT5 = titles(model, project)
        record("step dragged to level 0 becomes a task with its title, done state, due day and priority",
               promoted.map { $0.status == .done && $0.dueDay == Day.today() + 3 && $0.priorityRaw == 2 } == true
                && (store.task(t["T3"]!.id)?.orderedSubtasks.map(\.title) ?? []) == ["dnd.S2"] && store.undoDepth - depth == 1,
               "promoted=\(promoted.map { "status=\($0.status) due=\(String(describing: $0.dueDay)) prio=\($0.priorityRaw)" } ?? "none") undo=\(store.undoDepth - depth)")
        record("step dragged to level 0 lands where it was dropped (before T5)",
               beforeT5.firstIndex(of: "dnd.S1").map { $0 + 1 == beforeT5.firstIndex(of: "dnd.T5") } == true, "order=\(beforeT5)")
        store.undo(); model.didMutate(); await settle(); await expandAll()
        record("step promote: undo gives the step back with its id", snapshot(model, project) == before, "")

        // MARK: 7. step onto another task (after the hold)
        before = snapshot(model, project)
        depth = store.undoDepth
        _ = await drag(model, internalSubtask(s2, t["T3"]!), [DropStop(anchor: "row.dnd.T4", y: 0.5, dwellMs: 150)], end: .hover)
        try? await Task.sleep(for: .milliseconds(800))
        let moveHint = controller.feedback?.hint
        _ = await finish(overlay, controller, model, internalSubtask(s2, t["T3"]!), end: .drop)
        record("step dragged onto another task after the hold moves under it, one undo step",
               moveHint == .moveUnder && (store.task(t["T4"]!.id)?.orderedSubtasks.map(\.title) ?? []) == ["dnd.S2"] && store.undoDepth - depth == 1,
               "hint=\(String(describing: moveHint)) t4Steps=\(store.task(t["T4"]!.id)?.orderedSubtasks.map(\.title) ?? []) undo=\(store.undoDepth - depth)")
        store.undo(); model.didMutate(); await settle(); await expandAll()
        record("step move: undo restores the step under its first parent", snapshot(model, project) == before, "")

        // MARK: 8. external drops, between rows: a NEW task from the source
        ListDropController.mailSubject = { _ in nil }   // never the person's Mail data
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kronos-dnd-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let mailURL = "message:%3Cdnd-1%40example.test%3E"
        before = snapshot(model, project)
        depth = store.undoDepth
        _ = await drag(model, mailPasteboard(url: mailURL, subject: "Quarterly report"), [DropStop(anchor: "row.dnd.T2", y: 0.1, dwellMs: 200)], end: .hover)
        let newHint = UITestAnchors.frames["drop.hint"]
        let mailLine = UITestAnchors.frames["drop.line"]
        _ = await finish(overlay, controller, model, mailPasteboard(url: mailURL, subject: "Quarterly report"), end: .drop)
        var created = store.allTasks().first { $0.title == "Quarterly report" }
        let links = created.map { ContextLink.findAll(in: $0.notes) } ?? []
        order = titles(model, project)
        record("Mail dropped between rows: a new task titled with the subject and an email chip",
               created != nil && links.count == 1 && links[0].kind == .email && links[0].reference == mailURL && !links[0].reference.isEmpty,
               "task=\(created?.title ?? "none") links=\(links.map { "\($0.kind):\($0.reference)" })")
        record("Mail drop: line and 'New task' hint shown, one undo step, lands before the target row",
               newHint != nil && mailLine != nil && store.undoDepth - depth == 1
                && (order.firstIndex(of: "Quarterly report").map { $0 + 1 == order.firstIndex(of: "dnd.T2") } ?? false),
               "hint=\(newHint != nil) line=\(mailLine != nil) steps=\(store.undoDepth - depth) order=\(order)")
        store.undo(); model.didMutate(); await settle(); await expandAll()
        record("Mail drop: undo removes the new task", store.allTasks().first { $0.title == "Quarterly report" } == nil && snapshot(model, project) == before, "")

        // Mail with no subject on the pasteboard: Envelope Index fallback (injected), then the placeholder.
        ListDropController.mailSubject = { _ in "From the envelope index" }
        _ = await drag(model, mailPasteboard(url: "message:%3Cdnd-2%40example.test%3E", subject: nil), [DropStop(anchor: "row.dnd.T4", y: 0.9, dwellMs: 100)], end: .drop)
        try? await Task.sleep(for: .milliseconds(500))
        created = store.allTasks().first { $0.title == "From the envelope index" }
        record("Mail without a subject on the pasteboard: the subject comes from the Envelope Index lookup, chip still attached",
               created.map { ContextLink.findAll(in: $0.notes).first?.kind == .email } == true, "task=\(created?.title ?? "none")")
        store.undo(); model.didMutate(); await settle()
        ListDropController.mailSubject = { _ in nil }
        _ = await drag(model, mailPasteboard(url: "message:%3Cdnd-3%40example.test%3E", subject: nil), [DropStop(anchor: "row.dnd.T4", y: 0.9, dwellMs: 100)], end: .drop)
        try? await Task.sleep(for: .milliseconds(500))
        let placeholder = String(localized: "detail.links.email.untitled")
        created = store.allTasks().first { $0.title == placeholder }
        record("Mail with no subject anywhere: titled with the localised placeholder, link kept",
               created.map { ContextLink.findAll(in: $0.notes).count == 1 } == true, "task=\(created?.title ?? "none") want=\(placeholder)")
        store.undo(); model.didMutate(); await settle(); await expandAll()

        // Finder file and folder.
        let file = tmp.appendingPathComponent("dnd-report.final.pdf")
        try? Data("x".utf8).write(to: file)
        let folder = tmp.appendingPathComponent("dnd-folder.v2")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = await drag(model, filePasteboard([file, folder]), [DropStop(anchor: "row.dnd.T5", y: 0.9, dwellMs: 100)], end: .drop)
        let fileTask = store.allTasks().first { $0.title == "dnd-report.final" }
        let folderTask = store.allTasks().first { $0.title == "dnd-folder.v2" }
        let fileLinks = fileTask.map { ContextLink.findAll(in: $0.notes) } ?? []
        let folderLinks = folderTask.map { ContextLink.findAll(in: $0.notes) } ?? []
        record("Finder file: new task titled with the file name without extension and a file chip",
               fileLinks.count == 1 && fileLinks[0].kind == .file && !fileLinks[0].reference.isEmpty, "task=\(fileTask?.title ?? "none") links=\(fileLinks.map { $0.kind.rawValue })")
        record("Finder folder: new task keeps the whole folder name and a folder chip",
               folderLinks.count == 1 && folderLinks[0].kind == .folder && !folderLinks[0].reference.isEmpty, "task=\(folderTask?.title ?? "none") links=\(folderLinks.map { $0.kind.rawValue })")
        store.undo(); model.didMutate(); await settle()
        record("Finder drop of two items is one undo step", store.allTasks().first { $0.title == "dnd-report.final" } == nil
                && store.allTasks().first { $0.title == "dnd-folder.v2" } == nil, "")

        // Notes: the AppKit destination reads the Notes types; the id is looked up by title.
        let noteTitle = "DND note"
        model.notes = FixtureNotesBridge(notesByTitle: [noteTitle: [NoteInfo(id: "n-dnd", title: noteTitle, modifiedAt: Date())]])
        _ = await drag(model, notesPasteboard(text: "DND note\nsecond line"), [DropStop(anchor: "row.dnd.T5", y: 0.9, dwellMs: 100)], end: .drop)
        try? await Task.sleep(for: .milliseconds(400))
        let noteTask = store.allTasks().first { $0.title == "DND note" }
        let noteLinks = noteTask.map { ContextLink.findAll(in: $0.notes) } ?? []
        record("Notes drop (private note type): new task titled with the note title and an Apple note chip",
               noteLinks.count == 1 && noteLinks[0].kind == .appleNote && noteLinks[0].reference == "n-dnd", "task=\(noteTask?.title ?? "none") links=\(noteLinks.map { "\($0.kind.rawValue):\($0.reference)" })")
        store.undo(); model.didMutate(); await settle()
        _ = await drag(model, notesPasteboard(text: "Unknown note title"), [DropStop(anchor: "row.dnd.T5", y: 0.9, dwellMs: 100)], end: .drop)
        try? await Task.sleep(for: .milliseconds(400))
        let lonely = store.allTasks().first { $0.title == "Unknown note title" }
        record("Notes drop whose id cannot be found: a task with its title and NO empty chip",
               lonely != nil && !(lonely!.notes.contains("link://")), "notes=\(lonely?.notes ?? "none")")
        store.undo(); model.didMutate(); await settle(); await expandAll()

        // MARK: 9. external onto a row, after the hold: attach
        before = snapshot(model, project)
        depth = store.undoDepth
        let taskCount = store.allTasks().count
        _ = await drag(model, mailPasteboard(url: mailURL, subject: "Attach me"), [DropStop(anchor: "row.dnd.T2", y: 0.5, dwellMs: 150)], end: .hover)
        let attachEarly = controller.feedback?.hint
        try? await Task.sleep(for: .milliseconds(800))
        let attachHint = controller.feedback?.hint
        _ = await finish(overlay, controller, model, mailPasteboard(url: mailURL, subject: "Attach me"), end: .drop)
        let t2Links = store.task(t["T2"]!.id).map { ContextLink.findAll(in: $0.notes) } ?? []
        record("external item onto a task row: nothing before the hold, then the link is attached (no new task)",
               attachEarly == nil && attachHint == .attachLink && t2Links.count == 1 && t2Links[0].kind == .email
                && store.allTasks().count == taskCount && store.undoDepth - depth == 1,
               "early=\(String(describing: attachEarly)) hint=\(String(describing: attachHint)) links=\(t2Links.count) tasks=\(store.allTasks().count)/\(taskCount) steps=\(store.undoDepth - depth)")
        store.undo(); model.didMutate(); await settle()
        record("attach: undo removes the link", snapshot(model, project) == before, "")

        _ = await drag(model, mailPasteboard(url: mailURL, subject: "Attach to step"), [DropStop(anchor: "subrow.dnd.S1", y: 0.5, dwellMs: 150)], end: .hover)
        try? await Task.sleep(for: .milliseconds(800))
        _ = await finish(overlay, controller, model, mailPasteboard(url: mailURL, subject: "Attach to step"), end: .drop)
        let stepLinks = ContextLink.findAll(in: store.task(t["T3"]!.id)?.orderedSubtasks.first { $0.title == "dnd.S1" }?.notes ?? "")
        record("external item onto a subtask row, after the hold, attaches to that subtask", stepLinks.count == 1 && stepLinks[0].kind == .email, "links=\(stepLinks.count)")
        store.undo(); model.didMutate(); await settle(); await expandAll()

        // Plain text onto a row: nothing usable to attach, nothing stored.
        before = snapshot(model, project)
        _ = await drag(model, textPasteboard("just words"), [DropStop(anchor: "row.dnd.T1", y: 0.5, dwellMs: 150)], end: .hover)
        try? await Task.sleep(for: .milliseconds(800))
        let wordsDropped = await finish(overlay, controller, model, textPasteboard("just words"), end: .drop)
        record("plain text onto a row stores no empty link and changes nothing", !wordsDropped && snapshot(model, project) == before, "dropped=\(wordsDropped)")

        // MARK: 10. Esc / cancel
        before = snapshot(model, project)
        depth = store.undoDepth
        _ = await drag(model, internalTask("T4", t), [DropStop(anchor: "row.dnd.T1", y: 0.1, dwellMs: 150)], end: .hover)
        let shownWhileDragging = controller.feedback != nil && UITestAnchors.frames["drop.line"] != nil
        overlay.draggingExited(nil)   // what AppKit sends when Esc ends the session
        try? await Task.sleep(for: .milliseconds(200))
        record("Esc during a drag cancels: indicators gone, nothing changed, nothing pushed",
               shownWhileDragging && controller.feedback == nil && UITestAnchors.frames["drop.line"] == nil
                && store.undoDepth == depth && snapshot(model, project) == before,
               "shown=\(shownWhileDragging) after=\(controller.feedback == nil) line=\(UITestAnchors.frames["drop.line"] != nil) steps=\(store.undoDepth - depth)")

        // MARK: 11. sorted list: no reorder line, nest still works, external still creates
        let manualOptions = model.options(for: .project(project.id))
        model.setOptions(ViewOptions(sort: [.asc(.title)], filter: .empty, showCompleted: false), for: .project(project.id))
        try? await Task.sleep(for: .milliseconds(700))
        await expandAll()
        before = snapshot(model, project)
        depth = store.undoDepth
        _ = await drag(model, internalTask("T4", t), [DropStop(anchor: "row.dnd.T1", y: 0.1, dwellMs: 200)], end: .hover)
        let sortedLine = UITestAnchors.frames["drop.line"]
        let sortedDropped = await finish(overlay, controller, model, internalTask("T4", t), end: .drop)
        record("sorted list: no reorder line and an edge drop does nothing",
               sortedLine == nil && !sortedDropped && store.undoDepth == depth && snapshot(model, project) == before,
               "line=\(sortedLine != nil) dropped=\(sortedDropped)")
        _ = await drag(model, internalTask("T4", t), [DropStop(anchor: "row.dnd.T2", y: 0.5, dwellMs: 150)], end: .hover)
        try? await Task.sleep(for: .milliseconds(800))
        let sortedNest = controller.feedback?.hint
        _ = await finish(overlay, controller, model, internalTask("T4", t), end: .drop)
        record("sorted list: nesting still works",
               sortedNest == .nest && (store.task(t["T2"]!.id)?.orderedSubtasks.map(\.title) ?? []) == ["dnd.T4"] && store.undoDepth - depth == 1,
               "hint=\(String(describing: sortedNest)) steps=\(store.undoDepth - depth)")
        store.undo(); model.didMutate(); await settle(); await expandAll()
        _ = await drag(model, mailPasteboard(url: mailURL, subject: "Sorted arrival"), [DropStop(anchor: "row.dnd.T2", y: 0.1, dwellMs: 200)], end: .hover)
        let sortedHint = UITestAnchors.frames["drop.hint"], sortedLine2 = UITestAnchors.frames["drop.line"]
        _ = await finish(overlay, controller, model, mailPasteboard(url: mailURL, subject: "Sorted arrival"), end: .drop)
        record("sorted list: an external drop still creates a task, labelled, with no line",
               sortedHint != nil && sortedLine2 == nil && store.allTasks().contains { $0.title == "Sorted arrival" },
               "hint=\(sortedHint != nil) line=\(sortedLine2 != nil)")
        store.undo(); model.didMutate()
        model.setOptions(manualOptions, for: .project(project.id))
        try? await Task.sleep(for: .milliseconds(600))
        await expandAll()

        // MARK: 12. auto-scroll near the edges
        for n in 1...40 { let name = "dnd.bulk\(n)"; _ = store.create(title: name, project: project) }
        model.didMutate()
        try? await Task.sleep(for: .milliseconds(900))
        if let scrollView = overlay.listScrollView() {
            let startY = scrollView.contentView.bounds.origin.y
            let info = ScriptedDraggingInfo(pasteboard: internalTaskPasteboard("T4", t), location: overlayWindowPoint(overlay, x: 200, y: overlay.bounds.height - 8), window: mainWindow)
            _ = overlay.draggingEntered(info)
            _ = overlay.draggingUpdated(info)
            try? await Task.sleep(for: .milliseconds(700))
            let downY = scrollView.contentView.bounds.origin.y
            info.location = overlayWindowPoint(overlay, x: 200, y: 6)
            _ = overlay.draggingUpdated(info)
            try? await Task.sleep(for: .milliseconds(700))
            let upY = scrollView.contentView.bounds.origin.y
            info.location = overlayWindowPoint(overlay, x: 200, y: overlay.bounds.height / 2)
            _ = overlay.draggingUpdated(info)
            let rest = scrollView.contentView.bounds.origin.y
            try? await Task.sleep(for: .milliseconds(300))
            let afterRest = scrollView.contentView.bounds.origin.y
            overlay.draggingExited(nil)
            record("auto-scroll: the list scrolls down at the bottom edge, up at the top edge and stops in the middle",
                   downY > startY + 40 && upY < downY - 40 && abs(afterRest - rest) < 1,
                   "start=\(Int(startY)) down=\(Int(downY)) up=\(Int(upY)) rest=\(Int(rest))→\(Int(afterRest))")
        } else {
            record("auto-scroll: the list scrolls near the edges", false, "no NSScrollView under the overlay")
        }

        // MARK: 13. Envelope Index query on a hand-made database
        record("Mail message URL parsing", MailSubjectLookup.messageID(fromURL: "message:%3Cabc%40x.test%3E") == "abc@x.test"
                && MailSubjectLookup.messageID(fromURL: "message://%3Cabc%40x.test%3E") == "abc@x.test"
                && MailSubjectLookup.messageID(fromURL: "https://x.test") == nil && MailSubjectLookup.messageID(fromURL: "message:") == nil, "")
        let dbPath = tmp.appendingPathComponent("ei.sqlite").path
        let built = EnvelopeIndexFixture.build(at: dbPath, messageID: "<abc@x.test>", subject: "Hand made subject")
        record("Envelope Index lookup reads the subject by Message-ID, read-only; unknown id gives nil",
               built && MailSubjectLookup.query(databaseAt: dbPath, messageID: "abc@x.test") == "Hand made subject"
                && MailSubjectLookup.query(databaseAt: dbPath, messageID: "nope@x.test") == nil, "built=\(built)")

        // Tidy: soft-delete the fixture project's tasks, back to the earlier list.
        for task in store.allTasks() where task.project?.id == project.id { store.softDelete(task.id) }
        model.didMutate()
        model.scope = priorScope
        try? await Task.sleep(for: .milliseconds(300))
    }
}
#endif
