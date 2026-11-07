// Live steps for Review next, the one-card-at-a-time fast path (Kronos v1.2 Phase 2 slice D2):
// A approves, X opens a note field whose Return reopens the task with the comment, S skips
// writing nothing (this session only), Space expands/collapses the run details, and ⇧A
// approves every pending card from the same agent in one undo step. Every fixture goes through
// the real production path — `RunStore.finish(outcome: .done)`, which is what
// `AgentDoneReport.reportDone` (hand-written tables elsewhere) actually calls — rather than
// hand-setting `reviewRaw`. Run alone with `--only group:D-REVIEWNEXT`.
#if !RELEASE
import AppKit
import KronosCore

@MainActor
extension LiveUITest {
    static func dReviewNextSteps(_ model: AppModel) async {
        await runStep(model, scope: .all) { await drnApprove($0) }
        await runStep(model, scope: .all) { await drnRequestChanges($0) }
        await runStep(model, scope: .all) { await drnSkip($0) }
        await runStep(model, scope: .all) { await drnRunToggle($0) }
        await runStep(model, scope: .all) { await drnApproveAll($0) }
    }

    private static var drnBreak: Bool { ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil }

    /// Every item left `reviewRaw` pending/awaitingCheck by an earlier (failed) step is wiped
    /// back to none, and the card is closed — the same per-step contract `reviewReset`
    /// (LiveUITest+DReview.swift) uses for the full Review card. Also reclaims first responder
    /// from any stray text view: confirmed live, a card running right after F-BOARD's View
    /// Options popover can inherit a `PlatformTextView` first responder on the MAIN window
    /// itself (`resetState`'s own leaf-level clear runs before this leaf, not between its five
    /// sub-steps) — `ReviewNextKeys.handleKey` refuses every key, including A, while any text
    /// view holds first responder, so the queue never budges. Same guard `resetState` already
    /// applies at the top of every OTHER leaf.
    private static func drnReset(_ model: AppModel) async {
        model.isReviewNextOpen = false
        if window.firstResponder is NSTextView { window.makeFirstResponder(nil) }
        for t in model.store.allTasksIncludingSubtasks() where t.reviewRaw == 1 || t.reviewRaw == 4 {
            model.store.updateNoUndo(t.id) { $0.reviewRaw = 0 }
        }
        model.didMutate()
        await settle(250)
    }

    /// One agent-done, awaiting-check task: a plain open task delegated to `agent`, with a run
    /// started and finished `done` — the real production path (`RunStore.finish` calls
    /// `AgentDoneReport.reportDone`), not a hand-built `reviewRaw`.
    private static func drnTask(_ model: AppModel, _ runs: RunStore, _ agent: AgentIdentity, _ title: String,
                                summary: String, artifacts: [RunArtifact] = []) -> KTask? {
        let t = model.store.createNoUndo(title: title, notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
        model.store.updateNoUndo(t.id) { $0.agentID = agent.agentID; $0.assigneeRaw = 1 }
        guard let run = try? runs.start(taskID: t.id, agent: agent, launchedByKronos: false) else { return nil }
        try? runs.finish(runID: run.id, agent: agent, outcome: .done, summary: summary, artifactsAdd: artifacts, handoffTo: nil)
        return t
    }

    private static func drnOpen(_ model: AppModel) async -> Bool {
        model.isReviewNextOpen = true
        let up = await waitUntil(timeout: 3) { UITestAnchors.frames["review.next.card"] != nil }
        await settle(250)
        return up
    }

    private static func drnFixture(_ model: AppModel) -> (agent: AgentIdentity, runs: RunStore)? {
        guard let hub = try? AgentHub(directory: KronosStore.containerDirectory(), tokenFiles: nil),
              let made = hub.addAgent(displayName: "Drn Review Probe"),
              let identity = hub.identity(slug: made.agent.slug),
              let runs = model.runs ?? (try? RunStore(directory: KronosStore.containerDirectory(), store: model.store, hub: hub))
        else { return nil }
        return (identity, runs)
    }

    private static func drnRemoveAgent(_ slug: String) {
        (try? AgentHub(directory: KronosStore.containerDirectory(), tokenFiles: nil))?.remove(slug: slug)
    }

    // MARK: A approves

    private static func drnApprove(_ model: AppModel) async {
        await drnReset(model)
        let name = "Review next: A approves the current agent-done card and the drained queue closes"
        guard let fx = drnFixture(model) else { record(name, false, "could not seed a scratch agent"); return }
        defer { drnRemoveAgent(fx.agent.slug) }
        let store = model.store
        guard let t = drnTask(model, fx.runs, fx.agent, "drn.approve", summary: "Wrote the summary.") else {
            record(name, false, "could not seed a run"); return
        }
        model.didMutate()
        _ = await drnOpen(model)
        key("a", keyCode: 0)
        let done = await waitUntil(timeout: 2) { store.task(t.id)?.status == .done }
        await settle(250)
        let approved = store.task(t.id)?.status == .done && store.task(t.id)?.reviewRaw == ReviewState.approved
        let wantApproved = !drnBreak
        let closedAfter = await waitUntil(timeout: 2) { model.isReviewNextOpen == false }
        record(name, done && approved == wantApproved && closedAfter,
               "done=\(done) approved=\(approved) closed=\(closedAfter)")
    }

    // MARK: X opens a note field; Return sends it

    private static func drnRequestChanges(_ model: AppModel) async {
        await drnReset(model)
        let name = "Review next: X opens a note field, Return reopens the task with the comment stored"
        guard let fx = drnFixture(model) else { record(name, false, "could not seed a scratch agent"); return }
        defer { drnRemoveAgent(fx.agent.slug) }
        let store = model.store
        guard let t = drnTask(model, fx.runs, fx.agent, "drn.reject", summary: "Wrote the summary.") else {
            record(name, false, "could not seed a run"); return
        }
        model.didMutate()
        _ = await drnOpen(model)
        key("x", keyCode: 7)
        let fieldShown = await waitUntil(timeout: 2) { UITestAnchors.frames["review.next.note.field"] != nil }
        await settle(200)
        for ch in "needs another pass" { key(String(ch)); await settle(20) }
        key("\r", keyCode: 36)
        let reopened = await waitUntil(timeout: 2) { store.task(t.id)?.reviewRaw == 0 }
        await settle(200)
        let commented = (store.task(t.id)?.contextJSON ?? "").contains("needs another pass")
        let wantReopened = !drnBreak
        record(name, fieldShown && reopened == wantReopened && store.task(t.id)?.status != .done && commented,
               "fieldShown=\(fieldShown) reopened=\(reopened) commented=\(commented)")
    }

    // MARK: S skips, writing nothing

    private static func drnSkip(_ model: AppModel) async {
        await drnReset(model)
        let name = "Review next: S skips the current card, writing nothing, this session only"
        guard let fx = drnFixture(model) else { record(name, false, "could not seed a scratch agent"); return }
        defer { drnRemoveAgent(fx.agent.slug) }
        let store = model.store
        guard let t = drnTask(model, fx.runs, fx.agent, "drn.skip", summary: "Wrote the summary.") else {
            record(name, false, "could not seed a run"); return
        }
        model.didMutate()
        _ = await drnOpen(model)
        key("s", keyCode: 1)
        let closedAfter = await waitUntil(timeout: 2) { model.isReviewNextOpen == false }
        await settle(200)
        let untouched = store.task(t.id)?.reviewRaw == ReviewState.awaitingCheck && store.task(t.id)?.status == .todo
        let wantUntouched = !drnBreak
        record(name, closedAfter && untouched == wantUntouched,
               "closed=\(closedAfter) untouched=\(untouched) reviewRaw=\(String(describing: store.task(t.id)?.reviewRaw))")
    }

    // MARK: Space toggles the run details

    private static func drnRunToggle(_ model: AppModel) async {
        await drnReset(model)
        let name = "Review next: Space expands the run details (artifact chip shows) and collapses them again"
        guard let fx = drnFixture(model) else { record(name, false, "could not seed a scratch agent"); return }
        defer { drnRemoveAgent(fx.agent.slug) }
        guard drnTask(model, fx.runs, fx.agent, "drn.space", summary: "Wrote the summary.",
                     artifacts: [RunArtifact(kind: "url", ref: "https://example.com/drn-space-probe", title: "Probe artifact")]) != nil else {
            record(name, false, "could not seed a run"); return
        }
        model.didMutate()
        _ = await drnOpen(model)
        let toggleShown = await waitUntil(timeout: 2) { UITestAnchors.frames["review.next.run.toggle"] != nil }
        let collapsedFirst = UITestAnchors.frames["review.next.run.artifacts"] == nil
        key(" ", keyCode: 49)
        let expanded = await waitUntil(timeout: 2) { UITestAnchors.frames["review.next.run.artifacts"] != nil }
        await settle(150)
        key(" ", keyCode: 49)
        let collapsedAgain = await waitUntil(timeout: 2) { UITestAnchors.frames["review.next.run.artifacts"] == nil }
        let wantExpanded = !drnBreak
        record(name, toggleShown && collapsedFirst && expanded == wantExpanded && collapsedAgain,
               "toggleShown=\(toggleShown) collapsedFirst=\(collapsedFirst) expanded=\(expanded) collapsedAgain=\(collapsedAgain)")
    }

    // MARK: ⇧A approves every pending item from the same agent in one undo step

    private static func drnApproveAll(_ model: AppModel) async {
        await drnReset(model)
        let name = "Review next: ⇧A approves every pending card from the same agent in one undo step"
        guard let fx = drnFixture(model) else { record(name, false, "could not seed a scratch agent"); return }
        defer { drnRemoveAgent(fx.agent.slug) }
        let store = model.store
        guard let t1 = drnTask(model, fx.runs, fx.agent, "drn.approveall.1", summary: "Wrote the first summary."),
              let t2 = drnTask(model, fx.runs, fx.agent, "drn.approveall.2", summary: "Wrote the second summary.") else {
            record(name, false, "could not seed two runs"); return
        }
        model.didMutate()
        _ = await drnOpen(model)
        let buttonShown = await waitUntil(timeout: 2) { UITestAnchors.frames["review.next.approveall"] != nil }
        let depth = store.undoDepth
        key("a", modifiers: .shift, keyCode: 0)
        let bothApproved = await waitUntil(timeout: 2) {
            store.task(t1.id)?.status == .done && store.task(t2.id)?.status == .done
        }
        await settle(250)
        let oneStep = store.undoDepth - depth == 1
        let closedAfter = model.isReviewNextOpen == false
        let wantApproved = !drnBreak
        record(name, buttonShown && bothApproved == wantApproved && oneStep && closedAfter,
               "buttonShown=\(buttonShown) bothApproved=\(bothApproved) steps=\(store.undoDepth - depth) closed=\(closedAfter)")
    }
}
#endif
