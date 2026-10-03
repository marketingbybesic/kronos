// Live steps for the menu bar leaf. Run alone with `--only group:B2-MENUBAR`.
#if !RELEASE
import AppKit
import KronosCore

@MainActor
extension LiveUITest {
    static func b2MenuBarSteps(_ model: AppModel) async {
        await blockEndedWritesNothing(model)
        await barNextIsTheSharedResolver(model)
        await quietLinesAtThresholds(model)
        await tellOrdoReordersInOneUndoStep(model)
        await popoverChromeIsDark(model)
    }

    private static func storeFingerprint(_ model: AppModel) -> String {
        model.store.allTasks().map { "\($0.id)|\($0.sortIndex)|\($0.statusRaw)|\($0.notes)" }.sorted().joined(separator: "\n")
            + "|undo=\(model.store.undoDepth)|v=\(model.version)"
    }

    /// The ended prompt comes from the clock alone: a fixture clock moves past the block end, a tick
    /// runs, the prompt shows, and the store is byte-identical before and after.
    private static func blockEndedWritesNothing(_ model: AppModel) async {
        let breakMode = ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil
        let clock = FixtureClock(now: Date(timeIntervalSince1970: 1_790_000_000))
        let start = clock.now
        func event(_ id: String, _ title: String, _ from: TimeInterval, _ to: TimeInterval) -> TimeBlockEntry {
            TimeBlockEntry(event: KCalendarEvent(id: id, title: title, start: start.addingTimeInterval(from),
                                                 end: start.addingTimeInterval(to), isAllDay: false, calendarID: "fixture"),
                           projectID: nil)
        }
        _ = model.store.create(title: "Block probe task", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
        let blocks = TimeBlocksModel(model: model, clock: clock)
        blocks.setPreview(blocks: [event("b1", "Focus block", -600, 1800), event("b2", "Next block", 1800, 3600)], now: clock.now)
        let before = storeFingerprint(model)
        let shownEarly = blocks.showsEndedPrompt
        clock.now = start.addingTimeInterval(1799)
        blocks.tick()
        let shownJustBefore = blocks.showsEndedPrompt
        clock.now = start.addingTimeInterval(breakMode ? 1799 : 1800)
        blocks.tick()
        let shownAtEnd = blocks.showsEndedPrompt
        let after = storeFingerprint(model)
        record("Block ended appears at the block end from a clock tick, with no store mutation",
               !shownEarly && !shownJustBefore && shownAtEnd && before == after,
               "early=\(shownEarly) before=\(shownJustBefore) atEnd=\(shownAtEnd) storeSame=\(before == after)")
    }

    /// The bar and the popover pick `next` through the shared resolver: a done row at the head of
    /// the shown list is skipped, a pin wins, and the answer equals `AppModel.nextFromShownList`.
    private static func barNextIsTheSharedResolver(_ model: AppModel) async {
        let store = model.store
        let breakMode = ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil
        let done = store.create(title: "mb.done"); store.complete(done.id)
        let ok = store.create(title: "mb.ok")
        let pinTarget = store.create(title: "mb.pin")
        let before = model.shownListHead
        let wasPinned = model.pinnedFocusTaskID
        model.pinnedFocusTaskID = nil
        model.didMutate()
        model.publishShownListHead(ShownListHead(listName: "Today", ids: [done.id, ok.id, pinTarget.id]))
        let viaBar = MenuBarFocusResolver.taskID(model: model)
        let skipsDone = viaBar == (breakMode ? done.id : ok.id)
        let agrees = viaBar == model.nextFromShownList?.id
        model.pinnedFocusTaskID = pinTarget.id
        let pinWins = MenuBarFocusResolver.taskID(model: model) == pinTarget.id
        model.pinnedFocusTaskID = wasPinned
        model.publishShownListHead(before)
        model.didMutate()
        record("menu bar next: skips the done row, pin wins, same answer as the shared resolver",
               skipsDone && agrees && pinWins, "skipsDone=\(skipsDone) agrees=\(agrees) pinWins=\(pinWins)")
    }

    /// Time left from 20 min before a block ends, silent before; one switch turns the lines off.
    private static func quietLinesAtThresholds(_ model: AppModel) async {
        let clock = FixtureClock(now: Date(timeIntervalSince1970: 1_790_000_000))
        let start = clock.now
        let quiet = MenuBarQuiet(clock: clock)
        let events = [QuietEvent(title: "Globex call", start: start, end: start.addingTimeInterval(3600))]
        let wasOn = MenuBarPrefs.quietLines
        MenuBarPrefs.quietLines = true
        defer { MenuBarPrefs.quietLines = wasOn }
        clock.now = start.addingTimeInterval(2399)   // 1201 s left
        quiet.tick(model: model, events: events)
        let early = quiet.barSuffix
        clock.now = start.addingTimeInterval(2400)   // 1200 s left
        quiet.tick(model: model, events: events)
        let atThreshold = quiet.barSuffix
        MenuBarPrefs.quietLines = false
        quiet.tick(model: model, events: events)
        let optedOut = quiet.barSuffix == nil && quiet.popoverText == nil
        record("quiet lines: silent before 20 min left, '20 min left' at it, nothing when opted out",
               early == nil && atThreshold == " · 20 min left" && optedOut,
               "early=\(early ?? "nil") atThreshold=\(atThreshold ?? "nil") optedOut=\(optedOut)")
    }

    /// "Initech first" previews the new order without writing, Return-equivalent apply writes one undo
    /// step, and one undo restores every sort slot.
    private static func tellOrdoReordersInOneUndoStep(_ model: AppModel) async {
        let store = model.store
        let breakMode = ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil
        let a = store.create(title: "Send Acme invoice", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
        let b = store.create(title: "Initech bond page", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
        store.updateNoUndo(a.id) { $0.sortIndex = 5000 }
        store.updateNoUndo(b.id) { $0.sortIndex = 6000 }
        model.didMutate()
        let state = TellOrdoState()
        state.text = "Initech first"
        let queue = [store.task(a.id)!, store.task(b.id)!]
        let before = storeFingerprint(model)
        await state.submit(model: model, queue: queue)
        let previewOnly = state.preview?.ids == [b.id, a.id] && storeFingerprint(model) == before
        let depth = store.undoDepth
        state.apply(model: model)
        let oneStep = store.undoDepth == depth + 1
        let reordered = (store.task(b.id)?.sortIndex ?? .infinity) < (store.task(a.id)?.sortIndex ?? -.infinity)
            && model.pinnedFocusTaskID == b.id
        store.undo()
        model.pinnedFocusTaskID = nil
        model.didMutate()
        let restored = store.task(a.id)?.sortIndex == 5000 && store.task(b.id)?.sortIndex == (breakMode ? 1 : 6000)
        record("Tell Ordo: 'Initech first' previews with no write, applies as one undo step, undo restores the order",
               previewOnly && oneStep && reordered && restored,
               "preview=\(previewOnly) oneStep=\(oneStep) reordered=\(reordered) restored=\(restored)")
    }

    /// The popover's own frame is dark: the system chrome around the black content is dark aqua, not
    /// grey. The window is captured by the window server (CGWindowListCreateImage), so the real chrome is in
    /// the picture; the brightest channel on the frame ring (below the arrow band) must stay under 48.
    /// Where the capture is not allowed the step records that it could not measure, and fails.
    private static func popoverChromeIsDark(_ model: AppModel) async {
        let ordo = AppDelegate.shared.menuBarOrdo
        let opened = window.contentView.flatMap { ordo.showPopoverForUITest(from: $0) }
        await settle(800)
        guard let popoverWindow = opened else {
            record("menu bar popover: chrome is dark, no grey frame", false, "no popover window"); return
        }
        // CGWindowListCreateImage is marked unavailable in the current SDK but still ships; a window of
        // our own process needs no screen recording permission, so it is looked up by name.
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kronos-menubar-popover.png")
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
              let cg = unsafeBitCast(symbol, to: Capture.self)(.null, 8 /* optionIncludingWindow */, UInt32(popoverWindow.windowNumber),
                                                                 0 /* default: frame included */)?.takeRetainedValue() else {
            record("menu bar popover: chrome is dark, no grey frame", false, "window capture returned no picture; chrome not measured"); return
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        diagnostics.append("popover picture: \(url.path) \(rep.pixelsWide)x\(rep.pixelsHigh)")
        let w = rep.pixelsWide, h = rep.pixelsHigh
        let skipTop = 40   // the arrow and its shoulders
        var brightest = 0.0
        func look(_ x: Int, _ y: Int) {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.alphaComponent > 0.5 else { return }
            brightest = max(brightest, Double(max(c.redComponent, c.greenComponent, c.blueComponent)))
        }
        for y in skipTop..<h { for x in [1, 2, 3, w - 2, w - 3, w - 4] { look(x, y) } }
        for x in 0..<w { for y in [h - 2, h - 3, h - 4] { look(x, y) } }
        let darkAqua = popoverWindow.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let level = Int((brightest * 255).rounded())
        record("menu bar popover: chrome is dark aqua and its frame ring stays below channel 48 (no grey chrome)",
               darkAqua && level < 48, "darkAqua=\(darkAqua) brightestFrameChannel=\(level) picture=\(w)x\(h)")
        ordo.closePopoverForUITest()
        await settle(300)
    }
}
#endif
