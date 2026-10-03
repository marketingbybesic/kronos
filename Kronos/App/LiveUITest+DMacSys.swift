// Live steps for the macOS integration work: drag out of a row, Copy Kronos link, the Spotlight
// diff against a recording index, the Services entry for files and links, the Focus filter memory,
// the Reminders re-import, the parent cue and the launch kind. Run alone with `--only group:D-MACSYS`.
// Everything runs against the scratch store of the test run, private pasteboards and private
// defaults suites: the person's clipboard, Spotlight index, Reminders and Focus settings are never
// touched. `KRONOS_UITEST_BREAK=1` flips one expectation per step group: the run must then fail.
#if !RELEASE
import AppKit
import SwiftUI
import KronosCore

@MainActor
extension LiveUITest {
    static func dMacSysSteps(_ model: AppModel) async {
        let breakMode = ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil
        guard KronosEnv.isHermetic else { record("D-MACSYS runs only on a scratch store", false, "not hermetic"); return }
        await dragOutPayload(model, breakMode: breakMode)
        copyKronosLink(model, breakMode: breakMode)
        await spotlightDiff(model, breakMode: breakMode)
        servicesAddLink(model, breakMode: breakMode)
        focusFilterMemory(model, breakMode: breakMode)
        await remindersReimport(model, breakMode: breakMode)
        parentCueAndLaunchKind(model, breakMode: breakMode)
        await remindersOptionShot(model)
    }

    private static func privatePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("kronos.dmacsys.\(UUID().uuidString)"))
    }

    private static func loadData(_ provider: NSItemProvider, _ type: String) async -> Data? {
        await withCheckedContinuation { cont in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in cont.resume(returning: data) }
        }
    }

    // MARK: Drag out

    private static func dragOutPayload(_ model: AppModel, breakMode: Bool) async {
        let store = model.store
        let task = store.createNoUndo(title: "dmacsys drag probe")
        let provider = DragOut.provider(id: task.id, title: task.title, isChild: false)
        let types = provider.registeredTypeIdentifiers
        let first = types.first ?? ""
        let internalData = await loadData(provider, first)
        let internalText = internalData.flatMap { String(data: $0, encoding: .utf8) }
        record("drag out: the internal text stays the first type and is unchanged",
               first.contains("plain-text") && internalText == "kronos-task:\(task.id.uuidString)",
               "first=\(first) text=\(internalText ?? "nil")")
        let link = TaskLink.string(for: task.id)
        let urlData = await loadData(provider, DragOut.linkURLType)
        let urlText = urlData.flatMap { String(data: $0, encoding: .utf8) }
        let rtfData = await loadData(provider, DragOut.richTextType)
        let rich = rtfData.flatMap { NSAttributedString(rtf: $0, documentAttributes: nil) }
        let richLink = rich?.attribute(.link, at: 0, effectiveRange: nil)
        let richLinkText = (richLink as? URL)?.absoluteString ?? (richLink as? String)
        record("drag out: carries the kronos://open URL and the title with the link",
               urlText == (breakMode ? link + "x" : link) && rich?.string == task.title && richLinkText == link,
               "url=\(urlText ?? "nil") rtf=\(rich?.string ?? "nil") link=\(richLinkText ?? "nil") types=\(types)")
        // A rich text field takes the title as a link; the pasteboard a drop target reads still says "task".
        let pb = privatePasteboard()
        pb.clearContents()
        pb.declareTypes([.string, .rtf, .URL], owner: nil)
        pb.setString(internalText ?? "", forType: .string)
        if let rtfData { pb.setData(rtfData, forType: .rtf) }
        pb.setString(link, forType: .URL)
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        field.isRichText = true
        let read = field.readSelection(from: pb, type: .rtf)
        let fieldLink = field.textStorage.flatMap { $0.length > 0 ? $0.attribute(.link, at: 0, effectiveRange: nil) : nil }
        record("drag out: a rich text field receives the title as a Kronos link",
               read && field.string == task.title && ((fieldLink as? URL)?.absoluteString ?? fieldLink as? String) == link,
               "read=\(read) string=\(field.string) link=\(String(describing: fieldLink))")
        record("drag out: Kronos's own drop reader still sees a task row",
               DropZonePayloadReader.read(pb) == .task(task.id), "payload=\(DropZonePayloadReader.read(pb))")
        let child = store.addSubtaskNoUndo(task.id, title: "dmacsys child probe")
        if let child {
            let childProvider = DragOut.provider(id: child.id, title: child.title, isChild: true)
            let text = await loadData(childProvider, childProvider.registeredTypeIdentifiers.first ?? "").flatMap { String(data: $0, encoding: .utf8) }
            record("drag out: a child row keeps its own subtask text first",
                   text == "kronos-subtask:\(child.id.uuidString)", "text=\(text ?? "nil")")
        } else {
            record("drag out: a child row keeps its own subtask text first", false, "no child created")
        }
    }

    // MARK: Copy Kronos link

    private static func copyKronosLink(_ model: AppModel, breakMode: Bool) {
        let store = model.store
        guard let task = store.allTasks().first(where: { $0.title == "dmacsys drag probe" }) else {
            record("Copy Kronos link: probe task exists", false, "missing"); return
        }
        let nodes = TaskMenu.nodes(task: task, model: model, pickDue: {}, onSelect: {})
        let ids = CtxNodes.ids(nodes)
        let copyIndex = ids.firstIndex(of: "copy")
        let linkIndex = ids.firstIndex(of: "copyLink")
        record("Copy Kronos link: the task menu lists it right behind Copy",
               copyIndex != nil && linkIndex == copyIndex.map { $0 + 1 } && CtxNodes.find("copyLink", in: nodes)?.enabled == true,
               "ids=\(ids)")
        let child = task.orderedChildren.first
        let childIDs = child.map { CtxNodes.ids(TaskMenu.nodes(task: $0, model: model, pickDue: {}, onSelect: {})) } ?? []
        record("Copy Kronos link: a child task menu lists it too", childIDs.contains("copyLink"), "ids=\(childIDs)")
        let pb = privatePasteboard()
        let undoBefore = store.canUndo
        TaskMenu.copyLink(task.id, to: pb)
        let want = TaskLink.string(for: task.id) + (breakMode ? "x" : "")
        let parsed = pb.string(forType: .URL).flatMap { URL(string: $0) }.flatMap(KronosURLParser.parse)
        record("Copy Kronos link: the pasteboard holds the open link as URL and text, opening it parses back to the task",
               pb.string(forType: .URL) == want && pb.string(forType: .string) == want && parsed == .open(task.id)
                   && store.canUndo == undoBefore,
               "url=\(pb.string(forType: .URL) ?? "nil") text=\(pb.string(forType: .string) ?? "nil") parsed=\(String(describing: parsed))")
    }

    // MARK: Spotlight

    private static func spotlightDiff(_ model: AppModel, breakMode: Bool) async {
        let store = model.store
        // A task without steps: renaming a parent also changes its steps' subtitle, which is a real
        // change of those entries and would (rightly) re-index them too.
        let spotlightProbe = store.createNoUndo(title: "dmacsys spotlight probe")
        let recorder = FixtureSearchIndex()
        let indexer = SpotlightIndexer(model: model, index: recorder)
        await indexer.refreshNow()
        let firstCount = await recorder.indexedIDs.count
        await indexer.refreshNow()
        let untouched = await recorder.indexedIDs.count - firstCount
        let victim = spotlightProbe
        store.update(victim.id) { $0.title = "dmacsys spotlight probe renamed" }
        await indexer.refreshNow()
        let afterRename = await recorder.indexedIDs
        let delta = Array(afterRename.dropFirst(firstCount))
        record("Spotlight: a pass with no change re-indexes nothing, one rename re-indexes exactly one item",
               firstCount > 2 && untouched == 0 && delta == ["task.\(victim.id.uuidString)"] && delta.count == (breakMode ? 2 : 1),
               "first=\(firstCount) untouched=\(untouched) delta=\(delta)")
        store.softDelete(victim.id)
        await indexer.refreshNow()
        let deleted = await recorder.deletedIDs
        record("Spotlight: a deleted task leaves the index", deleted.contains("task.\(victim.id.uuidString)"), "deleted=\(deleted.count)")
        let facts = SpotlightIndexer.buildFacts(store: store, today: Day.today(calendar: KronosLocale.calendar))
        let anyTask = facts.first { $0.kind == .task }
        let anyProject = facts.first { $0.kind == .project }
        record("Spotlight: tasks carry a kronos://open content URL and keywords, projects are indexed and parse back",
               anyTask?.contentURL?.hasPrefix("kronos://open?id=") == true && anyTask?.keywords.contains("Kronos") == true
                   && anyProject.map { SpotlightIdentifier.parse($0.id) != nil } == true,
               "task=\(anyTask?.contentURL ?? "nil") project=\(anyProject?.id ?? "nil")")
        record("Spotlight: a scratch run uses the recording index, never the real one", KronosEnv.isHermetic, "hermetic=\(KronosEnv.isHermetic)")
    }

    // MARK: Services

    private static func servicesAddLink(_ model: AppModel, breakMode: Bool) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dmacsys-\(getpid())", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("macsys service probe.txt")
        try? "x".write(to: file, atomically: true, encoding: .utf8)
        let before = model.store.allTasks().count
        let pb = privatePasteboard()
        pb.clearContents()
        pb.writeObjects([file as NSURL])
        let made = ServicesProvider.addLinks(from: pb, model: model)
        let links = made.first.map { ContextLink.findAll(in: $0.notes) } ?? []
        record("Services: a file in Finder becomes one task with a file chip",
               made.count == 1 && made.first?.title == "macsys service probe" && links.count == 1
                   && links.first?.kind == .file && links.first?.reference.isEmpty == false
                   && model.store.allTasks().count == before + (breakMode ? 2 : 1),
               "made=\(made.map(\.title)) links=\(links.map(\.kind.rawValue)) tasks=\(model.store.allTasks().count - before)")
        let web = privatePasteboard()
        web.clearContents()
        web.setString("https://example.com/service-probe", forType: .URL)
        let madeWeb = ServicesProvider.addLinks(from: web, model: model)
        let webLinks = madeWeb.first.map { ContextLink.findAll(in: $0.notes) } ?? []
        record("Services: a web link becomes one task with a web chip",
               madeWeb.count == 1 && webLinks.first?.kind == .web && webLinks.first?.reference == "https://example.com/service-probe",
               "made=\(madeWeb.map(\.title)) links=\(webLinks.map(\.kind.rawValue))")
        let text = privatePasteboard()
        text.clearContents()
        text.setString("just some words", forType: .string)
        let blank = privatePasteboard()
        blank.clearContents()
        let n0 = model.store.allTasks().count
        let madeText = ServicesProvider.addLinks(from: text, model: model) + ServicesProvider.addLinks(from: blank, model: model)
        record("Services: plain text and an empty pasteboard add nothing",
               madeText.isEmpty && model.store.allTasks().count == n0, "made=\(madeText.count)")
        // The Info.plist entry itself is checked on the built bundle by the ledger: the guest build
        // regenerates Info.plist from project.yml, which does not list the service yet.
        record("Services: the provider answers the Add link message",
               ServicesProvider.instancesRespond(to: NSSelectorFromString("addLinkToKronos:userData:error:")),
               "selector answered")
        record("Services: a background capture flashes only when Kronos is not active and the run is not a scratch run",
               MenuBarFlash.shouldFlash(appIsActive: false, hermetic: false)
                   && !MenuBarFlash.shouldFlash(appIsActive: true, hermetic: false)
                   && !MenuBarFlash.shouldFlash(appIsActive: false, hermetic: true),
               "policy table")
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Focus filter

    private static func focusFilterMemory(_ model: AppModel, breakMode: Bool) {
        let name = "kronos.dmacsys.focus.\(getpid())"
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        let projectID = UUID()
        let first = FocusFilterMemory(defaults: suite)
        first.previousScope = .today
        first.appliedProject = projectID
        let relaunched = FocusFilterMemory(defaults: suite)
        record("Focus filter: the list to go back to and the Focus project survive a relaunch",
               relaunched.previousScope == (breakMode ? .inbox : .today) && relaunched.appliedProject == projectID,
               "previous=\(String(describing: relaunched.previousScope)) applied=\(String(describing: relaunched.appliedProject))")
        relaunched.previousScope = nil
        relaunched.appliedProject = nil
        record("Focus filter: clearing forgets both", FocusFilterMemory(defaults: suite).previousScope == nil
               && FocusFilterMemory(defaults: suite).appliedProject == nil, "cleared")

        // End to end through the real state: Focus on, relaunch, Focus off returns to the old list.
        let savedMemory = FocusFilterState.memory
        FocusFilterState.memory = FocusFilterMemory(defaults: suite)
        let project = model.store.createProject(name: "dmacsys focus project", colorHex: "#888888")
        let startScope = ListScope.today
        model.scope = startScope
        FocusFilterState.publish(projectID: project.id)
        FocusFilterState.apply(model: model)
        let onProject = model.scope == .project(project.id)
        FocusFilterState.memory = FocusFilterMemory(defaults: suite)   // a fresh process reads the same suite
        FocusFilterState.publish(projectID: nil)
        FocusFilterState.apply(model: model)
        record("Focus filter: Focus on opens the project, Focus off after a relaunch returns to the remembered list",
               onProject && model.scope == startScope, "onProject=\(onProject) scope=\(model.scope)")
        FocusFilterState.memory = savedMemory
        suite.removePersistentDomain(forName: name)
        model.scope = .all
    }

    // MARK: Reminders

    private static func remindersReimport(_ model: AppModel, breakMode: Bool) async {
        let store = model.store
        let one = ReminderItem(title: "dmacsys reminder one", notes: nil, due: nil, listName: "Nowhere", id: "R-ONE")
        let two = ReminderItem(title: "dmacsys reminder two", notes: nil, due: nil, listName: "Nowhere", id: "R-TWO")
        let recorder = RecordingReminders(items: [one])
        let savedFlag = RemindersImport.markComplete
        RemindersImport.markComplete = false

        let capture = CaptureModel(model: model)
        capture.remindersProvider = recorder
        await capture.importFromReminders()
        let firstRows = capture.rows.count
        for row in capture.rows { capture.setTicked(row.id, true) }
        capture.create()
        await settle(400)
        let stamped = store.allTasks().filter { $0.source == "reminders" }
        record("Reminders: a created task is stamped with the reminders source and its id",
               firstRows == 1 && stamped.count == 1 && stamped.first?.externalID == "reminders:R-ONE" && recorder.completed.isEmpty,
               "rows=\(firstRows) stamped=\(stamped.map { $0.externalID ?? "nil" }) completed=\(recorder.completed)")

        recorder.items = [one, two]
        RemindersImport.markComplete = true
        let again = CaptureModel(model: model)
        again.remindersProvider = recorder
        await again.importFromReminders()
        let rows2 = again.rows.map(\.proposal.title)
        for row in again.rows { again.setTicked(row.id, true) }
        again.create()
        await settle(400)
        let all = store.allTasks().filter { $0.title.hasPrefix("dmacsys reminder") }
        record("Reminders: importing twice offers only the new reminder and makes 0 duplicates",
               rows2 == ["dmacsys reminder two"] && all.count == (breakMode ? 3 : 2)
                   && Set(all.compactMap(\.externalID)) == ["reminders:R-ONE", "reminders:R-TWO"],
               "rows=\(rows2) tasks=\(all.map(\.title))")
        record("Reminders: the option completes only the reminder whose task was just made",
               recorder.completed == ["R-TWO"], "completed=\(recorder.completed)")

        recorder.items = [one, two]
        let third = CaptureModel(model: model)
        third.remindersProvider = recorder
        await third.importFromReminders()
        record("Reminders: when every reminder is known the import says so and shows nothing",
               third.rows.isEmpty && third.remindersState == .empty && RemindersImport.lastImportAllKnown,
               "rows=\(third.rows.count) state=\(third.remindersState) allKnown=\(RemindersImport.lastImportAllKnown)")
        RemindersImport.markComplete = savedFlag
    }

    // MARK: Parent cue and launch kind

    private static func parentCueAndLaunchKind(_ model: AppModel, breakMode: Bool) {
        let store = model.store
        let parent = store.createNoUndo(title: "dmacsys cue parent")
        guard let a = store.addSubtaskNoUndo(parent.id, title: "dmacsys cue a"),
              let b = store.addSubtaskNoUndo(parent.id, title: "dmacsys cue b") else {
            record("cue: parent with two steps", false, "could not create steps"); return
        }
        store.complete(a.id)
        let cueFirst = AppDelegate.completionCue(forSubtask: a.id, store: store)
        store.complete(b.id)
        let cueLast = AppDelegate.completionCue(forSubtask: b.id, store: store)
        record("cue: a step plays the step cue, the last open step of a parent plays the parent cue",
               cueFirst == .subtask && cueLast == (breakMode ? .subtask : .parent)
                   && AppDelegate.completionCue(forSubtask: nil, store: store) == .subtask
                   && AppDelegate.completionCue(forSubtask: UUID(), store: store) == .subtask,
               "first=\(cueFirst) last=\(cueLast)")
        record("launch kind: a scratch run is never a login launch",
               AppDelegate.shared.launchKind == (breakMode ? .login : .normal), "kind=\(AppDelegate.shared.launchKind)")
    }

    // MARK: Render of the one new control

    /// Renders the Capture paste step with Reminders access, so the "Also mark them complete" row is
    /// on screen, offscreen and without taking focus. The PNG goes to `KRONOS_SHOT_DIR` (or the
    /// leaf's shots folder when it exists); the step passes when the render is a full 520 pt card.
    private static func remindersOptionShot(_ model: AppModel) async {
        let capture = CaptureModel(model: model)
        capture.remindersProvider = RecordingReminders(items: [])
        let view = CapturePasteView(capture: capture, model: model)
            .frame(width: Metrics.inspectorMax, height: Metrics.inspectorMax)
            .background(Tok.bg)
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: Metrics.inspectorMax, height: Metrics.inspectorMax)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.backgroundColor = NSColor.black
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        await settle(500)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            record("design: the paste step with the Reminders option renders", false, "no bitmap"); return
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        let env = ProcessInfo.processInfo.environment
        let dir = env["KRONOS_SHOT_DIR"] ?? "/tmp/kronos-shots"
        var written = false
        if FileManager.default.fileExists(atPath: dir), let png = rep.representation(using: .png, properties: [:]) {
            written = (try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("capture-paste-reminders-en-M.png"))) != nil
        }
        // Measured from the render itself (a guest run cannot hand a PNG back): OLED corners, no red
        // hue anywhere, something drawn, and the option row is at least one hit target tall.
        let w = rep.pixelsWide, h = rep.pixelsHigh
        func rgb(_ x: Int, _ y: Int) -> (Double, Double, Double) {
            let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) ?? .black
            return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
        }
        let corners = [rgb(0, 0), rgb(w - 1, 0), rgb(0, h - 1), rgb(w - 1, h - 1)]
        let cornersBlack = corners.allSatisfy { $0.0 <= 1.0 / 255 && $0.1 <= 1.0 / 255 && $0.2 <= 1.0 / 255 }
        var lit = 0, red = 0
        for y in stride(from: 0, to: h, by: 2) {
            for x in stride(from: 0, to: w, by: 2) {
                let p = rgb(x, y)
                if max(p.0, p.1, p.2) > 0.1 { lit += 1 }
                if p.0 - max(p.1, p.2) > 0.08 { red += 1 }
            }
        }
        let row = NSHostingView(rootView: RemindersCompleteToggle().frame(width: Metrics.inspectorMax - 2 * Space.x5))
        let rowHeight = row.fittingSize.height
        record("design: the paste step with the Reminders option renders on OLED black, without red, with a hit-size option row",
               w >= 520 && h >= 520 && cornersBlack && lit > 50 && red == 0 && rowHeight >= Metrics.minHit,
               "px=\(w)x\(h) cornersBlack=\(cornersBlack) lit=\(lit) red=\(red) rowHeight=\(rowHeight) written=\(written)")
        win.contentView = nil
    }
}
#endif
