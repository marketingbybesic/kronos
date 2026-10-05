// Live steps for completing a task that waits on open tasks: the list checkbox raises the
// "Finish <B> first" card instead of completing, and each of the card's choices does what it says
// (Remove dependency and Complete both are one undo step each). Run alone with `--only group:I-BLOCK`.
#if !RELEASE
import AppKit
import KronosCore

@MainActor
extension LiveUITest {
    static func iBlockSteps(_ model: AppModel) async {
        let breakMode = ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil
        await setWindowSize(width: 1500, height: 900)
        await runStep(model, scope: .all) { await iBlockCard($0, breakMode: breakMode) }
        await runStep(model, scope: .all) { await iBlockChoices($0) }
        await runStep(model, scope: .all) { await iBlockKeysAndNesting($0) }
        await resetState(model)
    }

    /// Creates the probe tasks and narrows the list to them, so their rows are on screen.
    private static func iBlockSetup(_ model: AppModel, _ titles: [String]) async -> [KTask] {
        let store = model.store
        let tasks = titles.map { store.create(title: "IBlk " + $0) }
        model.searchText = "IBlk"
        model.didMutate()
        await settle(500)
        store.clearUndoHistory()
        return tasks
    }

    private static func iBlockTeardown(_ model: AppModel, _ tasks: [KTask]) {
        model.pendingBlockedCompletion = nil
        for t in tasks { model.store.softDeleteNoUndo(t.id) }
        model.searchText = ""
        model.didMutate()
    }

    /// Clicks the status circle of `task`'s row.
    private static func iBlockClickCircle(_ task: KTask) async -> Bool {
        await click("row." + task.title, xOffset: 6 + Metrics.listRowLeading + Metrics.listCheckboxSize / 2)
    }

    private static func iBlockCardUp(_ model: AppModel) async -> Bool {
        await waitUntil(timeout: 3) { model.pendingBlockedCompletion != nil && UITestAnchors.frames["blocked.card"] != nil }
    }

    // MARK: The card

    /// A waits on B: the circle shows the card, A stays open and nothing is written. A task with
    /// no open blocker still completes at once.
    private static func iBlockCard(_ model: AppModel, breakMode: Bool) async {
        let store = model.store
        let t = await iBlockSetup(model, ["A", "B", "Free"])
        let (a, b, free) = (t[0], t[1], t[2])
        defer { iBlockTeardown(model, t) }
        if !breakMode { store.setWaitsOnNoUndo(a.id, [b.id]) }
        model.didMutate()
        await settle(300)

        let clicked = await iBlockClickCircle(a)
        let up = await iBlockCardUp(model)
        await settle(300)
        record("clicking the circle of a task that waits on an open task shows the Finish card",
               clicked && up && model.pendingBlockedCompletion?.taskID == a.id && model.pendingBlockedCompletion?.blockerIDs == [b.id],
               "clicked=\(clicked) card=\(up) pending=\(String(describing: model.pendingBlockedCompletion?.blockerIDs.count))")
        record("the task stays open and nothing is written while the card is up",
               store.task(a.id)?.status != .done && store.task(b.id)?.status != .done && store.undoDepth == 0,
               "a=\(String(describing: store.task(a.id)?.status)) undoDepth=\(store.undoDepth)")
        let hasAll = ["blocked.open", "blocked.both", "blocked.remove", "blocked.cancel"].allSatisfy { UITestAnchors.frames[$0] != nil }
        record("the card offers Open, Complete both, Remove dependency and Cancel", hasAll,
               "anchors=\(["blocked.open", "blocked.both", "blocked.remove", "blocked.cancel"].map { UITestAnchors.frames[$0] != nil })")

        let cancelled = await click("blocked.cancel")
        await waitUntil(timeout: 2) { model.pendingBlockedCompletion == nil }
        record("Cancel closes the card and changes nothing",
               cancelled && model.pendingBlockedCompletion == nil && store.task(a.id)?.status != .done && store.task(a.id)?.waitsOn == [b.id],
               "pending=\(model.pendingBlockedCompletion != nil) a=\(String(describing: store.task(a.id)?.status))")

        _ = await iBlockClickCircle(free)
        let done = await waitUntil(timeout: 2) { store.task(free.id)?.status == .done }
        record("a task with no open blocker still completes at once, no card",
               done && model.pendingBlockedCompletion == nil, "done=\(done) pending=\(model.pendingBlockedCompletion != nil)")
    }

    // MARK: The choices

    private static func iBlockChoices(_ model: AppModel) async {
        let store = model.store
        let t = await iBlockSetup(model, ["A", "B"])
        let (a, b) = (t[0], t[1])
        defer { iBlockTeardown(model, t) }
        store.setWaitsOnNoUndo(a.id, [b.id])
        model.didMutate()
        await settle(300)

        // Remove dependency: A done, dependency gone, B untouched, one undo step restores both.
        _ = await iBlockClickCircle(a)
        _ = await iBlockCardUp(model)
        store.clearUndoHistory()
        let removed = await click("blocked.remove")
        let aDone = await waitUntil(timeout: 3) { store.task(a.id)?.status == .done }
        record("Remove dependency completes the task and drops the dependency",
               removed && aDone && store.task(a.id)?.waitsOn.isEmpty == true && store.task(b.id)?.status != .done && model.pendingBlockedCompletion == nil,
               "aDone=\(aDone) waitsOn=\(store.task(a.id)?.waitsOn.count ?? -1) b=\(String(describing: store.task(b.id)?.status))")
        let depth = store.undoDepth
        store.undo()
        model.didMutate()
        record("Remove dependency is one undo step that reopens the task and restores the dependency",
               depth == 1 && store.task(a.id)?.status != .done && store.task(a.id)?.waitsOn == [b.id],
               "depth=\(depth) a=\(String(describing: store.task(a.id)?.status)) waitsOn=\(store.task(a.id)?.waitsOn.count ?? -1)")
        await settle(1500)   // the row lingers about a second after a completion

        // Complete both: A and B done, one undo step reopens both.
        _ = await iBlockClickCircle(a)
        _ = await iBlockCardUp(model)
        store.clearUndoHistory()
        let both = await click("blocked.both")
        let bothDone = await waitUntil(timeout: 3) { store.task(a.id)?.status == .done && store.task(b.id)?.status == .done }
        let depth2 = store.undoDepth
        record("Complete both completes the blocker and the task in one undo step",
               both && bothDone && depth2 == 1 && model.pendingBlockedCompletion == nil,
               "bothDone=\(bothDone) depth=\(depth2)")
        store.undo()
        model.didMutate()
        record("one undo reopens both",
               store.task(a.id)?.status != .done && store.task(b.id)?.status != .done && store.task(a.id)?.waitsOn == [b.id],
               "a=\(String(describing: store.task(a.id)?.status)) b=\(String(describing: store.task(b.id)?.status))")
        await settle(1500)

        // Open <B>: the blocker is selected, A stays open.
        _ = await iBlockClickCircle(a)
        _ = await iBlockCardUp(model)
        let opened = await click("blocked.open")
        let selected = await waitUntil(timeout: 3) { model.selectedTaskID == b.id }
        record("Open selects the blocker and completes nothing",
               opened && selected && model.pendingBlockedCompletion == nil && store.task(a.id)?.status != .done && store.task(b.id)?.status != .done,
               "selectedIsB=\(model.selectedTaskID == b.id) a=\(String(describing: store.task(a.id)?.status))")
    }

    // MARK: Keys, several blockers, nested blockers

    private static func iBlockKeysAndNesting(_ model: AppModel) async {
        let store = model.store
        let t = await iBlockSetup(model, ["A", "B", "C", "D"])
        let (a, b, c, d) = (t[0], t[1], t[2], t[3])
        defer { iBlockTeardown(model, t) }

        // Two blockers: both listed, and Esc cancels from the keyboard.
        store.setWaitsOnNoUndo(a.id, [b.id, c.id])
        model.didMutate()
        await settle(300)
        _ = await iBlockClickCircle(a)
        _ = await iBlockCardUp(model)
        record("two open blockers are both named on the card",
               model.pendingBlockedCompletion?.blockerIDs == [b.id, c.id] && UITestAnchors.frames["blocked.both"] != nil,
               "blockers=\(model.pendingBlockedCompletion?.blockerIDs.count ?? -1)")
        key("\u{1b}", keyCode: 53)
        let closed = await waitUntil(timeout: 2) { model.pendingBlockedCompletion == nil }
        record("Esc cancels the card", closed && store.task(a.id)?.status != .done, "closed=\(closed)")

        // The B key is Complete both: the keyboard path ends with all three done.
        _ = await iBlockClickCircle(a)
        _ = await iBlockCardUp(model)
        key("b", keyCode: 11)
        let all = await waitUntil(timeout: 3) {
            [a.id, b.id, c.id].allSatisfy { store.task($0)?.status == .done }
        }
        record("key B completes every blocker and the task", all, "all=\(all)")
        store.undo()
        model.didMutate()
        store.setWaitsOnNoUndo(a.id, [])
        await settle(1500)

        // A blocker that is blocked itself: no Complete both.
        store.setWaitsOnNoUndo(a.id, [b.id])
        store.setWaitsOnNoUndo(b.id, [d.id])
        model.didMutate()
        await settle(300)
        _ = await iBlockClickCircle(a)
        let up = await iBlockCardUp(model)
        record("when the blocker is blocked itself the card hides Complete both",
               up && UITestAnchors.frames["blocked.both"] == nil && UITestAnchors.frames["blocked.remove"] != nil,
               "card=\(up) both=\(UITestAnchors.frames["blocked.both"] != nil)")
        key("\u{1b}", keyCode: 53)
        await waitUntil(timeout: 2) { model.pendingBlockedCompletion == nil }
    }
}
#endif
