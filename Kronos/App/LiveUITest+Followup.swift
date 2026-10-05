// Live steps for the follow-ups to blocked tasks: a locked row in the list while a task waits on an
// open task (and not after), and Triage leaving the keyboard to the "Finish <B> first" card.
// Run alone with `--only group:FOLLOWUP`. `KRONOS_UITEST_BREAK=1` skips the dependency write: the run must fail.
#if !RELEASE
import AppKit
import KronosCore

@MainActor
extension LiveUITest {
    static func followupSteps(_ model: AppModel) async {
        let breakMode = ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil
        guard KronosEnv.isHermetic else { record("FOLLOWUP runs only on a scratch store", false, "not hermetic"); return }
        // Set by vm/real-drag.sh inside a guest: no steps, only the app that a real OS drag starts from and lands on.
        if let dir = ProcessInfo.processInfo.environment["KRONOS_REALDRAG"], !dir.isEmpty {
            await followupRealDragHost(model, dir: dir)
            return
        }
        await setWindowSize(width: 1500, height: 900)
        await runStep(model, scope: .all) { await followupBlockedRow($0, breakMode: breakMode) }
        await runStep(model, scope: .all) { await followupTriageKeys($0, breakMode: breakMode) }
        await runStep(model, scope: .all) { await followupReviewAboveDetails($0, breakMode: breakMode) }
        await runStep(model, scope: .all) { await followupChildDrag($0, breakMode: breakMode) }
        await resetState(model)
    }

    private static func followupSetup(_ model: AppModel, _ titles: [String]) async -> [KTask] {
        let tasks = titles.map { model.store.create(title: "FUp " + $0) }
        model.searchText = "FUp"
        model.didMutate()
        await settle(500)
        model.store.clearUndoHistory()
        return tasks
    }

    private static func followupTeardown(_ model: AppModel, _ tasks: [KTask]) {
        model.pendingBlockedCompletion = nil
        model.isTriageOpen = false
        for t in tasks { model.store.softDeleteNoUndo(t.id) }
        model.searchText = ""
        model.didMutate()
    }

    // MARK: Lock on a blocked row

    private static func followupBlockedRow(_ model: AppModel, breakMode: Bool) async {
        let store = model.store
        let t = await followupSetup(model, ["A", "B", "C"])
        let (a, b, c) = (t[0], t[1], t[2])
        defer { followupTeardown(model, t) }
        func lock(_ task: KTask) -> Bool { UITestAnchors.frames["row.blocked." + task.title] != nil }

        let rowsUp = await waitUntil(timeout: 3) { UITestAnchors.frames["row." + a.title] != nil && UITestAnchors.frames["row." + b.title] != nil }
        record("rows with no dependency show no lock", rowsUp && !lock(a) && !lock(b) && !lock(c),
               "rows=\(rowsUp) a=\(lock(a)) b=\(lock(b)) c=\(lock(c))")

        if !breakMode { store.setWaitsOnNoUndo(a.id, [b.id]) }
        model.didMutate()
        let shown = await waitUntil(timeout: 3) { lock(a) }
        record("a row that waits on an open task shows the lock, the blocker and a free row do not",
               shown && !lock(b) && !lock(c), "a=\(lock(a)) b=\(lock(b)) c=\(lock(c))")

        // Tooltip wording, resolved through the same strings the row uses (hr is checked by the string table).
        let one = String(format: String(localized: "list.row.blocked.one"), b.title)
        let many = String(format: String(localized: "list.row.blocked.many"), 2)
        record("the tooltip names one blocker, or counts several",
               one == "Waiting on FUp B" && many == "Waiting on 2 tasks", "one=\(one) many=\(many)")

        // Two blockers keep the lock; finishing one of them keeps it, finishing the last removes it.
        store.setWaitsOnNoUndo(a.id, [b.id, c.id])
        model.didMutate()
        await settle(300)
        store.completeNoUndo(b.id)
        model.didMutate()
        await settle(400)
        let stillLocked = lock(a)
        store.completeNoUndo(c.id)
        model.didMutate()
        let gone = await waitUntil(timeout: 3) { !lock(a) }
        record("the lock stays while one blocker is open and goes when the last is done", stillLocked && gone,
               "stillLocked=\(stillLocked) gone=\(gone)")

        // Removing the dependency also removes the lock.
        store.updateNoUndo(b.id) { $0.status = .todo }
        store.setWaitsOnNoUndo(a.id, [b.id])
        model.didMutate()
        let back = await waitUntil(timeout: 3) { lock(a) }
        store.setWaitsOnNoUndo(a.id, [])
        model.didMutate()
        let removed = await waitUntil(timeout: 3) { !lock(a) }
        record("removing the dependency removes the lock", back && removed, "back=\(back) removed=\(removed)")
    }

    // MARK: Triage leaves the keys to the card

    /// The card is up BEFORE Triage opens, so Triage's key monitor is the newer one and sees each key first:
    /// without the guard it takes R (ask the AI again) and the card never gets Remove dependency.
    private static func followupTriageKeys(_ model: AppModel, breakMode: Bool) async {
        let store = model.store
        let t = await followupSetup(model, ["T1", "T2"])
        let (a, b) = (t[0], t[1])
        defer { followupTeardown(model, t) }
        store.setWaitsOnNoUndo(a.id, [b.id])
        model.didMutate()
        await settle(300)
        guard let task = store.task(a.id) else { record("Triage keys: probe exists", false, "missing"); return }
        let raised = model.interceptBlockedCompletion(of: task) { write in write() }
        model.isTriageOpen = true
        let both = await waitUntil(timeout: 4) { UITestAnchors.frames["triage.card"] != nil && UITestAnchors.frames["blocked.card"] != nil }
        await settle(300)
        record("Triage and the Finish card are both on screen", raised && both,
               "raised=\(raised) triage=\(UITestAnchors.frames["triage.card"] != nil) card=\(UITestAnchors.frames["blocked.card"] != nil)")
        store.clearUndoHistory()
        key("r", keyCode: 15)
        let done = await waitUntil(timeout: 3) { store.task(a.id)?.status == .done }
        record("R reaches the Finish card while Triage is open: Remove dependency completes the task",
               done && model.pendingBlockedCompletion == nil && store.task(a.id)?.waitsOn.isEmpty == true && store.task(b.id)?.status != .done,
               "done=\(done) pending=\(model.pendingBlockedCompletion != nil) waitsOn=\(store.task(a.id)?.waitsOn.count ?? -1)")
    }

    // MARK: Review verdict above Details

    /// A task waiting for the person's check shows Accept / Reject and the comment field with Details collapsed.
    private static func followupReviewAboveDetails(_ model: AppModel, breakMode: Bool) async {
        let store = model.store
        let key = "kronos.inspector.detailsOpen"
        let wasOpen = UserDefaults.standard.bool(forKey: key)
        UserDefaults.standard.set(false, forKey: key)
        let t = ReviewSnapshots.proposal(store, title: "FUp review", review: breakMode ? ReviewState.none : ReviewState.awaitingCheck,
                                         context: [:], result: ["note": "Written and saved."], assignee: 1)
        defer {
            UserDefaults.standard.set(wasOpen, forKey: key)
            store.softDeleteNoUndo(t.id)
            model.selectedTaskID = nil
            model.didMutate()
        }
        model.scope = .all
        model.searchText = ""
        model.didMutate()
        model.selectedTaskID = t.id
        let shown = await waitUntil(timeout: 4) { UITestAnchors.frames["inspector.review.accept"] != nil }
        await settle(300)
        let collapsed = UITestAnchors.frames["inspector.details.toggle"] != nil && UITestAnchors.frames["inspector.status.value"] == nil
        let all = ["inspector.review.accept", "inspector.review.reject", "inspector.review.comment"].allSatisfy { UITestAnchors.frames[$0] != nil }
        let aboveDetails = (UITestAnchors.frames["inspector.review.accept"]?.maxY ?? .infinity) <= (UITestAnchors.frames["inspector.details.toggle"]?.minY ?? 0)
        record("the verdict section (Accept, Reject, comment) shows above Details while Details is collapsed",
               shown && collapsed && all && aboveDetails,
               "shown=\(shown) collapsed=\(collapsed) all=\(all) aboveDetails=\(aboveDetails)")
    }

    // MARK: Subtask row drag

    private static func followupLoad(_ provider: NSItemProvider, _ type: String) async -> Data? {
        await withCheckedContinuation { cont in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in cont.resume(returning: data) }
        }
    }

    /// The drag a subtask row starts: the private type first with its own marker, the dossier as plain text, and
    /// Kronos's own reader still takes it for a subtask.
    private static func followupChildDrag(_ model: AppModel, breakMode: Bool) async {
        let store = model.store
        let parent = store.create(title: "FUp parent")
        guard let child = store.addSubtaskNoUndo(parent.id, title: "FUp child step") else {
            record("subtask drag: child exists", false, "no child"); return
        }
        store.update(child.id) { $0.notes = "Child notes." }
        defer { store.softDeleteNoUndo(parent.id); model.didMutate() }
        model.didMutate()
        guard let live = store.task(child.id) else { return }
        let provider = DragOut.provider(id: live.id, title: live.title, isChild: true,
                                        dossier: TaskDragText.render(TaskDragText.Input(task: live)))
        let types = provider.registeredTypeIdentifiers
        let marker = await followupLoad(provider, DropZonePayloadReader.dragItemTypeID).flatMap { String(data: $0, encoding: .utf8) }
        let plain = await followupLoad(provider, DragOut.plainTextType).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        record("subtask drag: the private type is first and carries the subtask marker",
               types.first == DropZonePayloadReader.dragItemTypeID && marker == "kronos-subtask:\(child.id.uuidString)",
               "types=\(types) marker=\(marker ?? "nil")")
        record("subtask drag: plain text is the dossier ending in the kronos link, not the marker",
               plain.hasPrefix("# FUp child step") && plain.contains("Child notes.") && plain.hasSuffix(TaskLink.string(for: child.id) + (breakMode ? "x" : ""))
                && !plain.contains("kronos-subtask:"), "plain=\(plain)")
        let pb = NSPasteboard(name: NSPasteboard.Name("kronos.followup.\(UUID().uuidString)"))
        pb.declareTypes(types.map { NSPasteboard.PasteboardType($0) }, owner: nil)
        for type in types { if let d = await followupLoad(provider, type) { pb.setData(d, forType: NSPasteboard.PasteboardType(type)) } }
        record("subtask drag: Kronos's own drop reader still reads it as that subtask",
               DropZonePayloadReader.read(pb) == .subtask(child.id), "payload=\(DropZonePayloadReader.read(pb))")
    }

    // MARK: Host for a real OS drag (vm/real-drag.sh drives the mouse from outside the app)

    /// Three tasks in a project of their own, the window parked at the top left, then a file protocol in `dir`:
    /// `req` (any text) asks for a fresh `frames.json` + `order.json`, answered by `ack`; `quit` ends the run.
    /// Frames are CG global points (origin top-left of the main display), what the mouse source posts events in.
    private static func followupRealDragHost(_ model: AppModel, dir: String) async {
        let store = model.store
        let project = store.createProject(name: "realdrag.project")
        let t = ["one", "two", "three"].map { store.create(title: "RDrag " + $0, project: project) }
        store.update(t[0].id) { $0.notes = "Real drag notes." }
        store.update(t[0].id) { $0.priority = .high }
        _ = store.addSubtaskNoUndo(t[0].id, title: "RDrag step")
        model.scope = .project(project.id)
        model.didMutate()
        window.makeKeyAndOrderFront(nil)
        let top = NSScreen.screens.first?.frame.height ?? 1200
        window.setFrame(NSRect(x: 0, y: top - 25 - 800, width: 1250, height: 800), display: true)
        await settle(900)
        let fm = FileManager.default
        func cg(_ f: CGRect) -> [String: Int] {
            guard let content = window.contentView else { return [:] }
            let local = NSRect(x: f.minX, y: content.isFlipped ? f.minY : content.bounds.height - f.maxY, width: f.width, height: f.height)
            let screen = window.convertToScreen(content.convert(local, to: nil))
            return ["x": Int(screen.minX), "y": Int(top - screen.maxY), "w": Int(screen.width), "h": Int(screen.height)]
        }
        func publish() {
            var rows: [String: Any] = [:]
            for task in t { if let f = UITestAnchors.frames["row." + task.title] { rows[task.title] = cg(f) } }
            let order = KTaskSorter.sorted(store.allTasks().filter { $0.project?.id == project.id }, by: [.asc(.manual)]).map(\.title)
            // Where the list's own drop controller puts the rows: what a drop is judged against.
            var dropRows: [String: Any] = [:]
            if let overlay = ListDropOverlayView.live, let controller = overlay.controller {
                let r = window.convertToScreen(overlay.convert(overlay.bounds, to: nil))
                for row in controller.rows {
                    guard let task = t.first(where: { $0.id == row.id }) else { continue }
                    dropRows[task.title] = ["x": Int(r.minX), "y": Int(top - r.maxY) + Int(row.minY), "w": Int(r.width), "h": Int(row.height)]
                }
            }
            let frames: [String: Any] = ["window": cg(CGRect(origin: .zero, size: window.contentView?.bounds.size ?? .zero)), "rows": rows, "dropRows": dropRows,
                                         "ids": Dictionary(uniqueKeysWithValues: t.map { ($0.title, $0.id.uuidString) })]
            // For a failed run: every task with its parent and manual position, steps included.
            let detail = store.allTasksIncludingSubtasks().filter { $0.title.hasPrefix("RDrag") }
                .map { "\($0.title) parent=\($0.parent?.title ?? "-") sortIndex=\($0.sortIndex) project=\($0.project?.name ?? "-")" }.sorted()
            for (name, object) in [("frames.json", frames as Any), ("order.json", order as Any), ("detail.json", detail as Any)] {
                if let data = try? JSONSerialization.data(withJSONObject: object) { try? data.write(to: URL(fileURLWithPath: dir + "/" + name)) }
            }
        }
        record("real drag host: three rows are on screen", await waitUntil(timeout: 5) { t.allSatisfy { UITestAnchors.frames["row." + $0.title] != nil } }, "")
        publish()
        fm.createFile(atPath: dir + "/ready", contents: Data("ready".utf8))
        let deadline = Date().addingTimeInterval(420)
        var trace = ""
        let t0 = Date()
        var lastLine = ""
        var lastGeo = Date.distantPast
        var geoLog = ""
        // One line per change: what the list's drop controller thinks (zone, row) and where the pointer is, so a drop
        // that did not happen can be read off afterwards. `live.txt` holds the newest state for the source.
        var lastState = ""
        func traceDrop() {
            let mouse = NSEvent.mouseLocation
            let ptr = "mouse=(\(Int(mouse.x)),\(Int(top - mouse.y)))"
            let state: String
            if let c = ListDropOverlayView.live?.controller, c.isActive, let r = c.currentResolution {
                let title = t.first { $0.id == r.rowID }?.title ?? "?"
                state = "zone=\(r.zone) row=\(title) lineY=\(r.lineY.map { String(Int($0)) } ?? "-")"
                if state != lastState { lastState = state; try? Data("\(state)\n".utf8).write(to: URL(fileURLWithPath: dir + "/live.txt")) }
            } else {
                state = "idle undo=\(store.undoDepth)"
            }
            let line = state + " " + ptr
            guard fm.fileExists(atPath: dir + "/trace.on"), line != lastLine else { return }
            lastLine = line
            trace += "\(Int(Date().timeIntervalSince(t0) * 1000)) \(line)\n"
            try? Data(trace.utf8).write(to: URL(fileURLWithPath: dir + "/trace.txt"))
        }
        while Date() < deadline, !fm.fileExists(atPath: dir + "/quit") {
            traceDrop()
            if fm.fileExists(atPath: dir + "/geo.on"), Date().timeIntervalSince(lastGeo) > 0.5, let o = ListDropOverlayView.live, let c = o.controller,
               let a = UITestAnchors.frames["row." + t[0].title], let r0 = c.rows.first(where: { $0.id == t[0].id }) {
                lastGeo = Date()
                let inWin = o.convert(o.bounds, to: nil)
                geoLog += "\(Int(Date().timeIntervalSince(t0) * 1000)) overlayInWindow=\(inWin) winH=\(window.frame.height) content=\(window.contentView?.frame ?? .zero) anchorRowOne=\(a) ctrlRowOne=\(r0.minY)-\(r0.maxY) near=\(UITestAnchors.frames.filter { $0.value.minY > 300 && $0.value.minY < 470 && $0.value.width > 100 }.map { "\($0.key)=\(Int($0.value.minY)),\(Int($0.value.height))" }.sorted()) ctrlFrames=\(c.rows.count) sel=\(model.selectedTaskID != nil)\n"
                try? Data(geoLog.utf8).write(to: URL(fileURLWithPath: dir + "/geo.txt"))
            }
            if fm.fileExists(atPath: dir + "/req") {
                try? fm.removeItem(atPath: dir + "/req")
                model.didMutate()
                await settle(500)
                publish()
                fm.createFile(atPath: dir + "/ack", contents: Data("ack".utf8))
            }
            await settle(40)
        }
        record("real drag host: ended by the driver", fm.fileExists(atPath: dir + "/quit"), "")
    }
}
#endif
