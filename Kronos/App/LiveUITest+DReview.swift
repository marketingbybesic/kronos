// Live steps for the Review queue. Run alone with `--only group:D-REVIEW`.
#if !RELEASE
import AppKit
import SwiftData
import KronosCore

@MainActor
extension LiveUITest {
    static func dReviewSteps(_ model: AppModel) async {
        await reviewHiddenEverywhere(model)
        await reviewQueueTable(model)
        await reviewSidebarRow(model)
        await reviewApproveStep(model)
        await reviewRejectStep(model)
        await reviewSnoozeAndEditSteps(model)
        await reviewBatchAndMergeSteps(model)
        await reviewAgentDoneSteps(model)
        await reviewDecisionEvents(model)
    }

    // MARK: Setup helpers

    private static var reviewToday: Int { Day.today(calendar: KronosLocale.calendar) }
    private static var reviewBreak: Bool { ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil }

    /// Every step starts with no proposal waiting, no "not now", and the flow closed.
    private static func reviewReset(_ model: AppModel) async {
        if model.isTriageOpen { model.isTriageOpen = false; await settle(300) }
        for t in model.store.allTasksIncludingSubtasks() where t.reviewRaw == 1 || t.reviewRaw == 4 {
            model.store.updateNoUndo(t.id) { $0.reviewRaw = 0 }
        }
        ReviewSnooze.clear()
        model.didMutate()
        window.makeKeyAndOrderFront(nil)
        await settle(200)
    }

    private static func reviewOpen(_ model: AppModel) async -> Bool {
        TriageLaunch.shared.request(.review)
        model.isTriageOpen = true
        let up = await waitUntil(timeout: 4) { UITestAnchors.frames["review.card.title"] != nil }
        await settle(350)
        return up
    }

    private static func reviewType(_ text: String) async {
        for ch in text { key(String(ch)); try? await Task.sleep(for: .milliseconds(30)) }
    }

    private static func reviewCreate(_ model: AppModel, _ title: String, review: Int = 1, context: [String: Any] = ["why": "A reason."],
                                     status: KStatus = .todo, project: KProject? = nil, due: Int? = nil, ageDays: Int = 0,
                                     result: [String: Any]? = nil, assignee: Int = 0, createdOffset: Double = 0) -> KTask {
        let task = ReviewSnapshots.proposal(model.store, title: title, review: review, context: context, result: result,
                                            assignee: assignee, project: project, status: status, dueDay: due)
        // Two writes: a tracked-field write stamps updatedAt itself, so the age is set last, alone.
        if createdOffset != 0 { model.store.updateNoUndo(task.id) { $0.createdAt = Date().addingTimeInterval(createdOffset) } }
        if ageDays > 0 { model.store.updateNoUndo(task.id) { $0.updatedAt = Date().addingTimeInterval(-86_400 * Double(ageDays)) } }
        return task
    }

    // MARK: Hidden everywhere

    private static func reviewHiddenEverywhere(_ model: AppModel) async {
        await reviewReset(model)
        let store = model.store
        let today = reviewToday
        let project = store.createProject(name: "dr.visibility", colorHex: KProjectPalette.swatches[3].hex, icon: "briefcase", area: nil)
        var pendingVisible = false, twinMissing: [String] = []
        let scopes: [(KStatus, ListScope)] = [(.todo, .all), (.waiting, .waiting), (.someday, .someday)]
        var pendings: [KTask] = [], twins: [KTask] = []
        for (status, scope) in scopes {
            let p = reviewCreate(model, "dr.vis.pending.\(status.rawValue)", status: status, project: project, due: today)
            let t = reviewCreate(model, "dr.vis.twin.\(status.rawValue)", review: 0, context: [:], status: status, project: project, due: today)
            pendings.append(p); twins.append(t)
            let all: [ListScope] = [.inbox, .today, .next7, .waiting, .someday, .all, .project(project.id)]
            if all.contains(where: { ScopeFilter.matches(p, scope: $0, today: today) || ScopeFilter.countsInSidebar(p, scope: $0, today: today) }) { pendingVisible = true }
            if !ScopeFilter.matches(t, scope: .project(project.id), today: today) { twinMissing.append("project \(status)") }
            if !ScopeFilter.matches(t, scope: scope, today: today) { twinMissing.append("\(scope)") }
        }
        var text = KFilter.empty
        text.text = "dr.vis"
        let viewHit = pendings.contains { text.matches($0, today: today) }
        let textTwin = twins.allSatisfy { text.matches($0, today: today) }
        let seen = pendingVisible || viewHit
        record("pending proposal is invisible in every scope, saved view, text filter and count; a normal task is not",
               seen == reviewBreak && twinMissing.isEmpty && textTwin,
               "pendingVisible=\(pendingVisible) viewHit=\(viewHit) twinMissing=\(twinMissing) textTwin=\(textTwin)")

        // Next, Sort and Sweep.
        let a = reviewCreate(model, "dr.next.pending", due: nil, ageDays: 30)
        let b = reviewCreate(model, "dr.next.twin", review: 0, context: [:], ageDays: 30)
        for id in [a.id, b.id] { store.updateNoUndo(id) { $0.needsTriage = true } }
        store.updateNoUndo(a.id) { $0.updatedAt = Date().addingTimeInterval(-86_400 * 30) }
        store.updateNoUndo(b.id) { $0.updatedAt = Date().addingTimeInterval(-86_400 * 30) }
        let all = store.allTasks()
        let nextA = NextEligibility.isEligible(a, lookup: all), nextB = NextEligibility.isEligible(b, lookup: all)
        let sorted = Set(TriageQueue.ordered(in: all).map(\.id))
        let swept = Set(SweepQueue.ordered(in: all, now: Date(), calendar: KronosLocale.calendar).map(\.id))
        let pendingIn = nextA || sorted.contains(a.id) || swept.contains(a.id)
        let twinIn = nextB && sorted.contains(b.id) && swept.contains(b.id)
        record("pending proposal is not next, not sorted, not swept; its twin is", pendingIn == reviewBreak && twinIn,
               "next=\(nextA)/\(nextB) sort=\(sorted.contains(a.id))/\(sorted.contains(b.id)) sweep=\(swept.contains(a.id))/\(swept.contains(b.id))")
        await reviewReset(model)
    }

    // MARK: Queue table

    private static func reviewQueueTable(_ model: AppModel) async {
        await reviewReset(model)
        let today = reviewToday
        let pid = UUID().uuidString
        let batchContext: [String: Any] = ["why": "Plan.", "proposalID": pid, "proposalTitle": "dr.plan"]
        let target = reviewCreate(model, "dr.q.target", review: 0, context: [:])
        // Oldest first by creation time (offsets are minutes apart, newest has the largest offset).
        let one = reviewCreate(model, "dr.q.one", createdOffset: -600)
        let b1 = reviewCreate(model, "dr.q.batch1", context: batchContext, createdOffset: -500)
        let b2 = reviewCreate(model, "dr.q.batch2", context: batchContext, createdOffset: -490)
        let upd = reviewCreate(model, "dr.q.update", context: ["kind": "update",
            "update": ["targetID": target.id.uuidString, "patch": ["priority": "high"]]], createdOffset: -400)
        let snoozed = reviewCreate(model, "dr.q.snoozed", createdOffset: -300)
        let done = reviewCreate(model, "dr.q.agentdone", review: 4, assignee: 1, createdOffset: -200)
        let decided = reviewCreate(model, "dr.q.decided", review: 2, createdOffset: -100)
        let mine: Set<UUID> = [one.id, b1.id, b2.id, upd.id, snoozed.id, done.id, decided.id]
        let all = model.store.allTasks()
        func shape(_ day: Int, _ table: [UUID: Int]) -> [String] {
            ReviewQueue.items(in: all, snoozed: table, today: day).filter { mine.contains($0.id) }.map {
                "\($0.primary.title)|\($0.kind)|\($0.members.count)"
            }
        }
        let now = shape(today, [snoozed.id: today + 1])
        let want = ["dr.q.one|proposal|1", "dr.q.batch1|batch|2", "dr.q.update|update|1", "dr.q.agentdone|agentDone|1"]
        let back = shape(today + 1, [snoozed.id: today + 1])
        let wantBack = ["dr.q.one|proposal|1", "dr.q.batch1|batch|2", "dr.q.update|update|1", "dr.q.snoozed|proposal|1", "dr.q.agentdone|agentDone|1"]
        let count = ReviewQueue.count(in: all, snoozed: [snoozed.id: today + 1], today: today)
        let expectNow = reviewBreak ? Array(want.reversed()) : want
        record("review queue table: oldest first, one card per batch, snoozed and decided out, agent-done kind",
               now == expectNow && back == wantBack && count >= 4, "now=\(now) back=\(back) count=\(count)")
        await reviewReset(model)
    }

    // MARK: Sidebar row

    private static func reviewSidebarRow(_ model: AppModel) async {
        await reviewReset(model)
        let absentBefore = await waitUntil(timeout: 2) { UITestAnchors.frames["sidebar.review"] == nil }
        let task = reviewCreate(model, "dr.row.proposal", due: reviewToday)
        model.didMutate()
        let shown = await waitUntil(timeout: 3) { UITestAnchors.frames["sidebar.review"] != nil }
        let count = ReviewQueue.count(in: model.store.allTasks(), snoozed: [:], today: reviewToday)
        var opened = false
        if shown, await click("sidebar.review") {
            opened = await waitUntil(timeout: 4) { model.isTriageOpen && UITestAnchors.frames["review.card.title"] != nil }
        }
        record("Review row shows only with a pending proposal and opens the card",
               absentBefore && shown == !reviewBreak && count == 1 && opened,
               "absentBefore=\(absentBefore) shown=\(shown) count=\(count) opened=\(opened)")
        await settle(300)
        key("\r", keyCode: 36)
        _ = await waitUntil { model.store.task(task.id)?.reviewRaw == 2 }
        key("\u{1B}", keyCode: 53)
        _ = await waitUntil { !model.isTriageOpen }
        let gone = await waitUntil(timeout: 3) { UITestAnchors.frames["sidebar.review"] == nil }
        record("Review row is gone after the last decision", gone, "gone=\(gone)")
        await reviewReset(model)
    }

    // MARK: Approve

    private static func reviewApproveStep(_ model: AppModel) async {
        await reviewReset(model)
        let store = model.store
        let task = reviewCreate(model, "dr.approve.visible", due: reviewToday)
        model.scope = .today
        model.didMutate()
        await settle(500)
        let before = UITestAnchors.frames["row.dr.approve.visible"] != nil
        let beforeData = ScopeFilter.matches(task, scope: .today, today: reviewToday)
        _ = await reviewOpen(model)
        let depth = store.undoDepth
        key("\r", keyCode: 36)
        _ = await waitUntil { store.task(task.id)?.reviewRaw == 2 }
        let one = store.undoDepth == depth + 1
        let pill = UndoToastCenter.shared.current != nil
        key("\u{1B}", keyCode: 53)
        _ = await waitUntil { !model.isTriageOpen }
        let after = await waitUntil(timeout: 4) { UITestAnchors.frames["row.dr.approve.visible"] != nil }
        record("Return approves: the proposal is not in Today before and is after, one undo step with a pill",
               !before && !beforeData && after == !reviewBreak && one && pill,
               "before=\(before)/\(beforeData) after=\(after) depth=\(store.undoDepth) was=\(depth) pill=\(pill)")
        await reviewReset(model)
    }

    // MARK: Reject

    private static func reviewRejectStep(_ model: AppModel) async {
        await reviewReset(model)
        let store = model.store
        let r1 = reviewCreate(model, "dr.reject.one", createdOffset: -300)
        let r2 = reviewCreate(model, "dr.reject.two", createdOffset: -200)
        let r3 = reviewCreate(model, "dr.reject.three", createdOffset: -100)
        model.didMutate()
        _ = await reviewOpen(model)
        key("\u{7F}", keyCode: 51)
        let asked = await waitUntil(timeout: 3) { UITestAnchors.frames["review.card.reason"] != nil }
        await settle(300)
        await reviewType("not needed")
        key("\r", keyCode: 36)
        _ = await waitUntil { store.task(r1.id)?.reviewRaw == 3 }
        let withReason = (store.taskIncludingDeleted(r1.id)?.resultJSON ?? "").contains("not needed")
        let goneOne = store.task(r1.id) == nil

        await settle(300)
        key("\u{7F}", keyCode: 51)
        _ = await waitUntil(timeout: 3) { UITestAnchors.frames["review.card.reason"] != nil }
        await settle(200)
        key("\t", keyCode: 48)
        _ = await waitUntil { store.taskIncludingDeleted(r2.id)?.reviewRaw == 3 }
        let noReason = !((store.taskIncludingDeleted(r2.id)?.resultJSON ?? "").contains("\"reason\""))

        await settle(300)
        key("\u{7F}", keyCode: 51)
        _ = await waitUntil(timeout: 3) { UITestAnchors.frames["review.card.reason"] != nil }
        await settle(200)
        key("\u{1B}", keyCode: 53)
        let closed = await waitUntil(timeout: 2) { UITestAnchors.frames["review.card.reason"] == nil }
        let untouched = store.task(r3.id)?.reviewRaw == 1 && model.isTriageOpen
        record("Delete asks for a reason: Return rejects with it, Tab without, Esc backs out",
               asked && withReason == !reviewBreak && goneOne && noReason && closed && untouched,
               "asked=\(asked) withReason=\(withReason) gone=\(goneOne) tabNoReason=\(noReason) escClosed=\(closed) untouched=\(untouched)")
        await reviewReset(model)
    }

    // MARK: Snooze, edit

    private static func reviewSnoozeAndEditSteps(_ model: AppModel) async {
        await reviewReset(model)
        let store = model.store
        let today = reviewToday
        let s1 = reviewCreate(model, "dr.snooze.one", createdOffset: -300)
        let s2 = reviewCreate(model, "dr.snooze.two", createdOffset: -200)
        model.didMutate()
        _ = await reviewOpen(model)
        key("s")
        _ = await waitUntil { ReviewSnooze.table[s1.id] != nil }
        let hidden = store.task(s1.id)?.reviewRaw == 1 && !ScopeFilter.matches(s1, scope: .all, today: today)
        let table = ReviewSnooze.table[s1.id]
        let next = ReviewQueue.ordered(in: store.allTasks(), snoozed: ReviewSnooze.table, today: today).first?.id
        let tomorrow = ReviewQueue.ordered(in: store.allTasks(), snoozed: ReviewSnooze.table, today: today + 1).first?.id
        record("S puts a proposal off until tomorrow and it stays hidden",
               hidden && table == today + (reviewBreak ? 2 : 1) && next == s2.id && tomorrow == s1.id,
               "hidden=\(hidden) until=\(String(describing: table)) today=\(today) next=\(next == s2.id) tomorrow=\(tomorrow == s1.id)")

        await settle(300)
        key("e")
        let fields = await waitUntil(timeout: 3) { UITestAnchors.frames["review.card.fields"] != nil }
        key("3")
        _ = await waitUntil { store.task(s2.id)?.priority == .high }
        key("\r", keyCode: 36)
        _ = await waitUntil { store.task(s2.id)?.reviewRaw == 2 }
        let result = store.task(s2.id)?.resultJSON ?? ""
        record("E then a field key then Return approves and records the edited field",
               fields && store.task(s2.id)?.priority == .high && result.contains("\"priority\"") == !reviewBreak,
               "fields=\(fields) priority=\(String(describing: store.task(s2.id)?.priority)) result=\(result)")
        await reviewReset(model)
    }

    // MARK: Batch, merge

    private static func reviewBatchAndMergeSteps(_ model: AppModel) async {
        await reviewReset(model)
        let store = model.store
        let pid = UUID().uuidString
        let ctx: [String: Any] = ["why": "A plan.", "proposalID": pid, "proposalTitle": "dr.plan.title"]
        let members = (1...3).map { reviewCreate(model, "dr.batch.\($0)", context: ctx, createdOffset: Double(-300 + $0)) }
        model.didMutate()
        _ = await reviewOpen(model)
        let depth = store.undoDepth
        key("\r", modifiers: [.command], keyCode: 36)
        _ = await waitUntil { members.allSatisfy { store.task($0.id)?.reviewRaw == 2 } }
        let all = members.allSatisfy { store.task($0.id)?.reviewRaw == 2 }
        record("Command-Return approves the whole batch in one undo step",
               all && store.undoDepth == depth + (reviewBreak ? 2 : 1), "all=\(all) depth=\(store.undoDepth) was=\(depth)")
        await reviewReset(model)

        let target = reviewCreate(model, "dr.merge.twin", review: 0, context: [:])
        let proposal = reviewCreate(model, "dr.merge.twin", context: ["why": "Same thing."])
        store.updateNoUndo(proposal.id) { $0.firstMove = "dr merge first move" }
        model.didMutate()
        _ = await reviewOpen(model)
        key("m")
        _ = await waitUntil { store.task(proposal.id) == nil }
        let live = store.allTasks().filter { $0.title == "dr.merge.twin" }
        let filled = store.task(target.id)?.firstMove == "dr merge first move"
        record("M merges the proposal into the similar open task",
               live.count == (reviewBreak ? 2 : 1) && live.first?.id == target.id && filled,
               "rows=\(live.count) kept=\(live.first?.id == target.id) firstMove=\(String(describing: store.task(target.id)?.firstMove))")
        await reviewReset(model)
    }

    // MARK: Agent-done

    private static func reviewAgentDoneSteps(_ model: AppModel) async {
        await reviewReset(model)
        let store = model.store
        let note: [String: Any] = ["note": "Written and saved."]
        let a1 = reviewCreate(model, "dr.done.accept", review: 4, context: [:], result: note, assignee: 1, createdOffset: -300)
        let a2 = reviewCreate(model, "dr.done.reopen", review: 4, context: [:], result: note, assignee: 1, createdOffset: -200)
        model.didMutate()
        _ = await reviewOpen(model)
        key("\r", keyCode: 36)
        _ = await waitUntil { store.task(a1.id)?.status == .done }
        let accepted = store.task(a1.id)?.status == .done && store.task(a1.id)?.reviewRaw == 2
        record("agent-done card: Return accepts and completes", accepted == !reviewBreak, "status=\(String(describing: store.task(a1.id)?.status))")

        await settle(400)
        key("r")
        let asked = await waitUntil(timeout: 3) { UITestAnchors.frames["review.card.reason"] != nil }
        await settle(300)
        await reviewType("needs the link")
        key("\r", keyCode: 36)
        _ = await waitUntil { store.task(a2.id)?.reviewRaw == 0 }
        let t = store.task(a2.id)
        let stored = (t?.contextJSON ?? "").contains("needs the link")
        record("agent-done card: R with a line reopens and stores the comment",
               asked && t?.reviewRaw == 0 && t?.status != .done && stored, "asked=\(asked) review=\(String(describing: t?.reviewRaw)) comment=\(stored)")
        await reviewReset(model)
    }

    // MARK: Events

    /// The person's three decisions on an agent's work, made on the real card, are each ONE event
    /// for that agent after the log's sync, and a second sync adds nothing.
    private static func reviewDecisionEvents(_ model: AppModel) async {
        await reviewReset(model)
        let store = model.store
        guard let container = try? KronosLocalStore.makeContainer(inMemory: true) else {
            record("decisions reach the agent as one event each", false, "no scratch agent container"); return
        }
        let hub = AgentHub(context: ModelContext(container), tokenFiles: nil)
        let agent = hub.register(slug: "dr-agent")
        func own(_ title: String, review: Int, offset: Double, assignee: Int = 0) -> KTask {
            let t = reviewCreate(model, title, review: review, context: [:], result: review == 4 ? ["note": "Done."] : nil,
                                 assignee: assignee, createdOffset: offset)
            store.updateNoUndo(t.id) { $0.agentID = agent.id }
            if review == 1 {
                hub.append(actor: "agent:dr-agent", verb: ActivityVerb.created, taskID: t.id, agentID: agent.id,
                           payload: ["review": .number(1)])
            }
            return t
        }
        let ok = own("dr.event.approve", review: 1, offset: -300)
        let no = own("dr.event.reject", review: 1, offset: -200)
        let done = own("dr.event.done", review: 4, offset: -100, assignee: 1)
        model.didMutate()
        _ = await reviewOpen(model)
        key("\r", keyCode: 36)
        _ = await waitUntil { store.task(ok.id)?.reviewRaw == 2 }
        await settle(300)
        key("\u{7F}", keyCode: 51)
        _ = await waitUntil(timeout: 3) { UITestAnchors.frames["review.card.reason"] != nil }
        await settle(300)
        await reviewType("wrong list")
        key("\r", keyCode: 36)
        _ = await waitUntil { store.taskIncludingDeleted(no.id)?.reviewRaw == 3 }
        await settle(300)
        key("\r", keyCode: 36)
        _ = await waitUntil { store.task(done.id)?.status == .done }

        let written = hub.sync(store: store)
        let rows = hub.rows()
        func events(_ verb: String, _ id: UUID) -> [KActivity] { rows.filter { $0.verb == verb && $0.taskID == id } }
        let approved = events(ActivityVerb.approved, ok.id).count
        let rejected = events(ActivityVerb.rejected, no.id)
        let reason = rejected.first.map { $0.payloadJSON.contains("wrong list") } ?? false
        let completed = events(ActivityVerb.completed, done.id).count
        let again = hub.sync(store: store)
        record("decisions reach the agent as one event each",
               approved == (reviewBreak ? 2 : 1) && rejected.count == 1 && reason && completed == 1 && again == 0,
               "written=\(written) approved=\(approved) rejected=\(rejected.count) reason=\(reason) completed=\(completed) second=\(again)")
        await reviewReset(model)
    }
}
#endif
