// Live steps for the agent hand-off/stop list keys (Kronos v1.2 Phase 2 slice C3): ⌃⌘H opens
// the hand-off picker and clicking the pre-highlighted agent's row delegates with an undo
// pill; ⌃⇧⌘H opens the same picker for an agent with no pinned harness, and clicking that row
// shows a refusal pill naming the reason, writing nothing; ⌘. stops a seeded active run. Run
// alone with `--only group:C-AGENTKEYS`.
#if !RELEASE
import AppKit
import KronosCore

@MainActor
extension LiveUITest {
    static func cAgentKeysSteps(_ model: AppModel) async {
        reacquireMainWindow()
        // A dedicated project, same reasoning as E-FLOW/F-BOARD: the live demo seed leaves
        // ~29 open tasks in `.all`, and a freshly created task can sort/scroll outside the
        // rendered (lazy) rows, so `cakSelect`'s click silently never finds its row.
        let project = model.store.createProject(name: "cak.agentkeys.probe")
        await runStep(model, scope: .project(project.id)) { await cakHandoffSteps($0, project) }
        await runStep(model, scope: .project(project.id)) { await cakStopStep($0, project) }
    }

    private static var cakBreak: Bool { ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil }

    // MARK: Helpers (mirrors LiveUITest+CList.swift's cSelect/pillSays)

    private static func cakTask(_ model: AppModel, _ title: String, _ project: KProject) -> KTask {
        model.store.createNoUndo(title: title, notes: "", project: project, status: .todo, priority: .none, dueDay: nil)
    }

    @discardableResult
    private static func cakSelect(_ model: AppModel, _ task: KTask) async -> Bool {
        model.selectedIDs = []
        if window.firstResponder is NSTextView { window.makeFirstResponder(nil) }
        let clicked = await click("row." + task.title, xFraction: 0.45)
        let ok = await waitUntil(timeout: 2) { model.selectedTaskID == task.id }
        await settle(150)
        return clicked && ok
    }

    private static func cakPillSays(_ text: String) -> Bool {
        UndoToastCenter.shared.current?.message.contains(text) == true
    }

    private static let cakLastUsedKey = "kronos.handoff.lastAgentSlug"

    /// The hand-off picker is a `.popover(item:)` — a separate key window, same as the project
    /// picker's own live-test precedent (LiveUITest+CList.swift) — so `window` must be
    /// retargeted at it before a click resolves against `ListHandoffPick`'s own content. The
    /// picker never becomes the GENUINE `NSApp.keyWindow` under a synthetic `NSApp.postEvent`
    /// (confirmed live: `NSApp.keyWindow` stays on `main`), so `.onKeyPress(.return)` inside it
    /// never fires — the same class of limitation `OptionChordMonitor.swift` documents for
    /// Option-held chords. A click on the agent's own row is unaffected (mouse events hit-test
    /// correctly by window number regardless of key status) and proves the same thing Return
    /// would: picking the row delegates (its own `pick()` calls `close()`, so no separate
    /// dismiss step is needed).
    private static func cakOpenPicker(_ main: NSWindow) async -> Bool {
        let opened = await waitUntil(timeout: 2) { UITestAnchors.frames["list.handoff.picker"] != nil }
        let pop = await awaitPopoverWindow(excluding: main)
        if let pop { window = pop }
        return opened && pop != nil
    }

    private static func cakHandoffSteps(_ model: AppModel, _ project: KProject) async {
        guard let seed = try? AgentHub(directory: KronosStore.containerDirectory(), tokenFiles: nil),
              let made = seed.addAgent(displayName: "Cak Handoff Probe") else {
            record("⌃⌘H opens the hand-off picker; picking the agent delegates with a pill and one undo step", false, "could not seed a scratch agent")
            record("⌃⇧⌘H with no harness pinned refuses with a pill naming the reason, writing nothing", false, "could not seed a scratch agent")
            return
        }
        let slug = made.agent.slug
        // Pre-seed "last used" so the picker always pre-highlights THIS agent regardless of how
        // many other agents exist or in what order — deterministic without needing arrow-key nav.
        let priorLastUsed = KronosEnv.defaults.string(forKey: cakLastUsedKey)
        KronosEnv.defaults.set(slug, forKey: cakLastUsedKey)
        defer {
            (try? AgentHub(directory: KronosStore.containerDirectory(), tokenFiles: nil))?.remove(slug: slug)
            if let priorLastUsed { KronosEnv.defaults.set(priorLastUsed, forKey: cakLastUsedKey) }
            else { KronosEnv.defaults.removeObject(forKey: cakLastUsedKey) }
        }
        let store = model.store
        let main = window!

        // ⌃⌘H: the picker opens pre-highlighting the seeded agent; clicking its row delegates.
        let t1 = cakTask(model, "cak.handoff.probe", project)
        model.didMutate()
        _ = await cakSelect(model, t1)
        let depth = store.undoDepth
        key("h", modifiers: [.control, .command], keyCode: 4)
        let opened = await cakOpenPicker(main)
        await settle(200)
        let picked = await click("list.handoff.agent." + slug)
        _ = await waitUntil(timeout: 2) { store.task(t1.id)?.agentID == made.agent.id }
        // `close()` is called synchronously inside `pick()`, same action as the delegation —
        // the anchor disappearing is a rendering-lag measurement on this non-key popover
        // window (see cakOpenPicker's doc comment), not part of what this step proves.
        let closed = await waitUntil(timeout: 2) { UITestAnchors.frames["list.handoff.picker"] == nil }
        window = main
        let delegated = store.task(t1.id)?.agentID == made.agent.id && store.task(t1.id)?.assigneeRaw == 1
        let wantDelegated = !cakBreak
        record("⌃⌘H opens the hand-off picker; picking the agent delegates with a pill and one undo step",
               opened && picked && delegated == wantDelegated && store.undoDepth - depth == 1 && cakPillSays(t1.title),
               "opened=\(opened) picked=\(picked) closed=\(closed) delegated=\(delegated) steps=\(store.undoDepth - depth) pill=\(UndoToastCenter.shared.current?.message ?? "nil")")

        // ⌃⇧⌘H: same picker, same pre-highlighted agent, who has no harness pinned — the
        // refusal pill names the reason and nothing is written (no delegation, no undo step).
        UndoToastCenter.shared.dismiss()
        let t2 = cakTask(model, "cak.handoffrun.probe", project)
        model.didMutate()
        _ = await cakSelect(model, t2)
        let depth2 = store.undoDepth
        key("h", modifiers: [.control, .command, .shift], keyCode: 4)
        let opened2 = await cakOpenPicker(main)
        await settle(200)
        let picked2 = await click("list.handoff.agent." + slug)
        await settle(400)
        window = main
        let reasons = [String(localized: "run.launch.noharness"), String(localized: "agents.harness.unpinned")]
        let message = UndoToastCenter.shared.current?.message ?? ""
        let refused = UndoToastCenter.shared.current?.isNotice == true && reasons.contains(message)
        let stillUndelegated = store.task(t2.id)?.agentID == nil
        let wantUndelegated = !cakBreak
        record("⌃⇧⌘H with no harness pinned refuses with a pill naming the reason, writing nothing",
               opened2 && picked2 && refused && stillUndelegated == wantUndelegated && store.undoDepth == depth2,
               "opened=\(opened2) picked=\(picked2) refused=\(refused) message=\"\(message)\" undelegated=\(stillUndelegated) steps=\(store.undoDepth - depth2)")
    }

    // MARK: ⌘. stops a seeded active run

    private static func cakStopStep(_ model: AppModel, _ project: KProject) async {
        let store = model.store
        guard let runs = model.runs ?? (try? RunStore(directory: KronosStore.containerDirectory(), store: store, hub: AppDelegate.shared?.mcpLive.hub)) else {
            record("⌘. stops the selected task's seeded active run and shows a pill naming the agent", false, "no runs store")
            return
        }
        let task = cakTask(model, "cak.stop.probe", project)
        model.didMutate()
        guard let run = try? runs.start(taskID: task.id, agent: nil, launchedByKronos: false) else {
            record("⌘. stops the selected task's seeded active run and shows a pill naming the agent", false, "could not seed an active run")
            return
        }
        _ = await cakSelect(model, task)
        key(".", modifiers: .command, keyCode: 47)
        let stopped = await waitUntil(timeout: 2) { runs.run(id: run.id)?.stateRaw == "stopped" }
        let wantStopped = !cakBreak
        let agentName = RunAgentNaming.displayName(forSlug: run.agentSlug)
        record("⌘. stops the selected task's seeded active run and shows a pill naming the agent",
               stopped == wantStopped && cakPillSays(agentName),
               "stopped=\(stopped) state=\(runs.run(id: run.id)?.stateRaw ?? "nil") pill=\(UndoToastCenter.shared.current?.message ?? "nil")")
    }
}
#endif
