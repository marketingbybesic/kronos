// Kronos/App/LiveUITest+TriageKeys.swift
// Triage card keys (reported dead twice).
#if !RELEASE
import AppKit
import SwiftUI
import KronosCore

@MainActor
extension LiveUITest {
    /// 8. Triage card keys (reported dead twice). Digits write the CURRENT card's priority, so which
    /// task changed tells us whether Tab and Return really moved on. Expected tasks are derived here
    /// from the store, not read back from the card.
    static func triageKeys(_ model: AppModel, leaveFieldBy rowID: String) async {
        let store = model.store
        _ = await click(rowID, xFraction: 0.45)          // leave the inline text field
        await waitUntil { !(window.firstResponder is NSTextView) }
        var seen: [UUID] = []
        func next() -> KTask? { TriageQueue.ordered(in: store.allTasks()).first { !seen.contains($0.id) } }
        guard let first = next() else { record("triage has a queue", false, ""); return }
        model.isTriageOpen = true
        await waitUntil(timeout: 4) { UITestAnchors.frames["triage.card"] != nil }
        await settle(200)
        record("triage card is on screen", UITestAnchors.frames["triage.card"] != nil, "")

        key("4"); await waitUntil { store.task(first.id)?.priority == .urgent }
        record("triage key 4 sets urgent on the first card", store.task(first.id)?.priority == .urgent, "\(String(describing: store.task(first.id)?.priority))")
        // A second field key must keep the first value instead of overwriting it.
        key("s"); await waitUntil { store.task(first.id)?.effort == .s }; await settle(300)
        record("triage key s sets effort and KEEPS the urgent priority",
               store.task(first.id)?.effort == .s && store.task(first.id)?.priority == .urgent,
               "effort=\(String(describing: store.task(first.id)?.effort)) priority=\(String(describing: store.task(first.id)?.priority))")

        seen.append(first.id)
        // Once priority + effort are set, a task that already has a project leaves the queue and the card
        // moves on by itself: Tab then skips THAT card, so it counts as seen too.
        if !TriageQueue.ordered(in: store.allTasks()).contains(where: { $0.id == first.id }), let onCard = next() { seen.append(onCard.id) }
        key("\t", keyCode: 48); await settle(400)   // the card advancing is not observable in the store
        guard let second = next() else { record("triage has a second task", false, ""); return }
        key("3"); await waitUntil { store.task(second.id)?.priority == .high }
        record("triage Tab skips to the next card", store.task(second.id)?.priority == .high && store.task(first.id)?.priority == .urgent,
               "second=\(String(describing: store.task(second.id)?.priority)) first=\(String(describing: store.task(first.id)?.priority))")

        seen.append(second.id)
        key("\r", keyCode: 36); await settle(500)   // the card advancing is not observable in the store
        guard let third = next() else { record("triage has a third task", false, ""); return }
        key("2"); await waitUntil { store.task(third.id)?.priority == .medium }
        record("triage Return accepts and moves on", store.task(third.id)?.priority == .medium && store.task(second.id)?.priority == .high,
               "third=\(String(describing: store.task(third.id)?.priority)) second=\(String(describing: store.task(second.id)?.priority))")

        key("\u{1B}", keyCode: 53); await waitUntil { !model.isTriageOpen }
        record("triage Esc closes", !model.isTriageOpen, "open=\(model.isTriageOpen)")
    }
}

// MARK: - Grammar on the triage cards. Run alone with `--only group:C-TRIAGE`.
// Every step presses keys only (no clicks). `KRONOS_UITEST_BREAK=1` flips one expectation per group.

@MainActor
extension LiveUITest {
    static func cTriageSteps(_ model: AppModel) async {
        let breakMode = ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil
        guard KronosEnv.isHermetic else { record("triage[C]: runs only on a scratch store", false, "not hermetic"); return }
        await grammarOnSortCard(model, breakMode: breakMode)
        await grammarOnSweepCard(model, breakMode: breakMode)
        await aiSetupKey(model, breakMode: breakMode)
        // The Sweep and Review cards share this dispatch. Run alone, this leaf's run also replays
        // their own steps, so one lane run covers everything the key handler serves (a full run
        // reaches them through their own registry lines).
        if ProcessInfo.processInfo.environment["KRONOS_UITEST_ONLY"] == "group:C-TRIAGE" {
            for replay in [b2TriageSteps, dReviewSteps] {
                if model.isTriageOpen { model.isTriageOpen = false; await settle(300) }
                model.store.clearUndoHistory()
                await replay(model)
            }
        }
    }

    /// A router with no usable provider: every ask throws, which the card reads as "AI is not set up".
    private struct NoKeyRouter: AIRouting {
        func triage(title: String, notes: String, projectNames: [String], labelNames: [String], today: Int,
                    lockedFields: Set<String>, context: TriageContext) async throws -> TriageResult { throw AIError.noUsableProvider }
        func retriage(title: String, notes: String, previous: TriageResult, feedback: String,
                      projectNames: [String], labelNames: [String], today: Int) async throws -> TriageResult { previous }
        func impulsPick(candidates: [Candidate], energy: KEnergyLevel, language: String) async throws -> ImpulsRanking { ImpulsRanking(ranked: []) }
        func ordoResort(queueTitles: [String], message: String, history: [String], language: String) async throws -> OrdoResort { .unchanged(queueCount: 0) }
        func extractTasks(from text: String, projectNames: [String], existingOpenTitles: [String], today: Int) async -> ExtractResult {
            ExtractResult(tasks: [], droppedLineCount: 0, isDeterministic: true, reason: .aiOff)
        }
        func breakdown(title: String, notes: String, existingSubtasks: [String]) async -> BreakdownResult {
            BreakdownResult(subtasks: [], firstMove: "", isDeterministic: true)
        }
    }

    /// What an observer closure saw; a class so the closure can write it.
    private final class Seen: @unchecked Sendable {
        var id: UUID?
        var tab: String?
    }

    private static func openTriage(_ model: AppModel, _ mode: TriageMode) async -> Bool {
        if model.isTriageOpen { model.isTriageOpen = false; await settle(300) }
        _ = await ensureKey()
        TriageLaunch.shared.request(mode)
        model.isTriageOpen = true
        let anchor = mode == .sweep ? "sweep.card.age" : "triage.card.progress"
        let shown = await waitUntil(timeout: 4) { UITestAnchors.frames[anchor] != nil }
        await settle(300)
        return shown
    }

    private static func pillMentions(_ title: String) -> Bool {
        UndoToastCenter.shared.current?.message.contains(title) == true
    }

    // MARK: Sort card

    private static func grammarOnSortCard(_ model: AppModel, breakMode: Bool) async {
        let store = model.store
        let today = Day.today(calendar: KronosLocale.calendar)
        // Seven probes, oldest first so they are the first cards whatever else the store holds.
        var p: [KTask] = []
        for i in 0..<7 { p.append(store.create(title: "Grammar probe \(i)")) }
        // A task that is already waiting and still to be sorted: W on its card lets it go again.
        p.append(store.create(title: "Grammar probe 7", notes: "", project: nil, status: .waiting, priority: .none, dueDay: nil))
        for (i, t) in p.enumerated() { store.updateNoUndo(t.id) { $0.createdAt = Date(timeIntervalSince1970: 1_000_000 + Double(i)) } }
        model.didMutate()
        let opened = await openTriage(model, .sort)
        let first = TriageQueue.ordered(in: store.allTasks()).first?.id
        record("triage[C] grammar: the sort card opens on the first probe", opened && first == p[0].id, "opened=\(opened) first=\(String(describing: first)) want=\(p[0].id)")

        // T plans today and keeps the card; the deadline is untouched; a second T writes nothing.
        var depth = store.undoDepth
        key("t")
        _ = await waitUntil { store.task(p[0].id)?.plannedDay == today }
        let wantDay = breakMode ? today + 1 : today
        record("triage[C] T plans for today in one undo step with a pill and keeps the card",
               store.task(p[0].id)?.plannedDay == wantDay && store.task(p[0].id)?.dueDay == nil && store.task(p[0].id)?.needsTriage == true
                   && store.undoDepth == depth + 1 && pillMentions(p[0].title),
               "planned=\(String(describing: store.task(p[0].id)?.plannedDay)) today=\(today) depth=\(store.undoDepth) was=\(depth)")
        let planned = await waitUntil(timeout: 2) { UITestAnchors.frames["triage.card.planned"] != nil }
        record("triage[C] the card names the planned day", planned, "anchor=\(planned)")
        depth = store.undoDepth
        key("t"); await settle(250)
        record("triage[C] a second T changes nothing and pushes no undo step", store.undoDepth == depth, "depth=\(store.undoDepth) was=\(depth)")
        key("z", modifiers: .command, keyCode: 6)
        _ = await waitUntil { store.task(p[0].id)?.plannedDay == nil }
        record("triage[C] Cmd-Z undoes T", store.task(p[0].id)?.plannedDay == nil, "planned=\(String(describing: store.task(p[0].id)?.plannedDay))")

        // 0 and 3 write the priority of the card on screen; an unbound key writes nothing.
        key("3"); _ = await waitUntil { store.task(p[0].id)?.priority == .high }
        let high = store.task(p[0].id)?.priority == .high
        key("0"); _ = await waitUntil { store.task(p[0].id)?.priority == KPriority.none }
        record("triage[C] 3 sets high and 0 clears the priority", high && store.task(p[0].id)?.priority == KPriority.none,
               "high=\(high) now=\(String(describing: store.task(p[0].id)?.priority))")
        depth = store.undoDepth
        key("x"); await settle(250)
        record("triage[C] an unbound key writes nothing", store.undoDepth == depth, "depth=\(store.undoDepth) was=\(depth)")

        // Shift-T plans tomorrow, marks the card as sorted, moves on: ONE undo step with a pill.
        depth = store.undoDepth
        key("T", modifiers: .shift)
        _ = await waitUntil { store.task(p[0].id)?.plannedDay == today + 1 }
        let t0 = store.task(p[0].id)
        record("triage[C] Shift-T plans for tomorrow, marks it sorted and leaves the card in one undo step",
               t0?.plannedDay == today + 1 && t0?.needsTriage == false && store.undoDepth == depth + 1 && pillMentions(p[0].title),
               "planned=\(String(describing: t0?.plannedDay)) needsTriage=\(String(describing: t0?.needsTriage)) depth=\(store.undoDepth) was=\(depth)")

        // H, W, Y act on the NEXT card each (the card moved on).
        depth = store.undoDepth
        key("h")
        _ = await waitUntil { store.task(p[1].id)?.plannedDay == today + 1 }
        record("triage[C] H snoozes the card to tomorrow and moves on", store.task(p[1].id)?.plannedDay == today + 1 && store.task(p[1].id)?.needsTriage == false && store.undoDepth == depth + 1,
               "planned=\(String(describing: store.task(p[1].id)?.plannedDay)) depth=\(store.undoDepth) was=\(depth)")
        depth = store.undoDepth
        key("w")
        _ = await waitUntil { store.task(p[2].id)?.status == .waiting }
        record("triage[C] W parks the card as waiting and moves on", store.task(p[2].id)?.status == .waiting && store.task(p[2].id)?.needsTriage == false && store.undoDepth == depth + 1 && pillMentions(p[2].title),
               "status=\(String(describing: store.task(p[2].id)?.status)) depth=\(store.undoDepth) was=\(depth)")
        depth = store.undoDepth
        key("y")
        _ = await waitUntil { store.task(p[3].id)?.status == .someday }
        record("triage[C] Y moves the card to Someday in one undo step", store.task(p[3].id)?.status == .someday && store.task(p[3].id)?.needsTriage == false && store.undoDepth == depth + 1,
               "status=\(String(describing: store.task(p[3].id)?.status)) depth=\(store.undoDepth) was=\(depth)")
        key("z", modifiers: .command, keyCode: 6)
        _ = await waitUntil { store.task(p[3].id)?.status == .todo }
        record("triage[C] one Cmd-Z brings the Someday card back with its triage flag",
               store.task(p[3].id)?.status == .todo && store.task(p[3].id)?.needsTriage == true,
               "status=\(String(describing: store.task(p[3].id)?.status)) needsTriage=\(String(describing: store.task(p[3].id)?.needsTriage))")

        // F pins and unpins the card's task (the pill carries its own undo); E and D open their fields, Esc closes them.
        model.pinnedFocusTaskID = nil
        key("f")
        _ = await waitUntil { model.pinnedFocusTaskID == p[4].id }
        let pinned = model.pinnedFocusTaskID == p[4].id
        key("f")
        _ = await waitUntil { model.pinnedFocusTaskID == nil }
        record("triage[C] F pins the card's task as focus and the next F unpins it", pinned && model.pinnedFocusTaskID == nil,
               "pinned=\(pinned) after=\(String(describing: model.pinnedFocusTaskID))")
        key("e")
        let move = await waitUntil(timeout: 2) { UITestAnchors.frames["triage.card.firstmove.field"] != nil }
        key("\u{1B}", keyCode: 53)
        let moveGone = await waitUntil(timeout: 2) { UITestAnchors.frames["triage.card.firstmove.field"] == nil }
        record("triage[C] E opens the first-move field and Esc closes it without closing triage", move && moveGone && model.isTriageOpen, "open=\(move) gone=\(moveGone) triage=\(model.isTriageOpen)")
        key("d")
        let date = await waitUntil(timeout: 2) { UITestAnchors.frames["triage.card.date"] != nil }
        key("\u{1B}", keyCode: 53)
        let dateGone = await waitUntil(timeout: 2) { UITestAnchors.frames["triage.card.date"] == nil }
        record("triage[C] D opens the date field and Esc closes it", date && dateGone && model.isTriageOpen, "open=\(date) gone=\(dateGone)")

        // B leaves triage, opens the task in the inspector, and asks for the break-down preview.
        let seen = Seen()
        let token = NotificationCenter.default.addObserver(forName: Notification.Name("kronosBreakdownRequested"), object: nil, queue: .main) { note in
            seen.id = note.userInfo?["taskID"] as? UUID
        }
        key("b")
        _ = await waitUntil { !model.isTriageOpen }
        _ = await waitUntil(timeout: 2) { seen.id != nil }
        NotificationCenter.default.removeObserver(token)
        record("triage[C] B closes triage, selects the task and requests its break-down preview",
               !model.isTriageOpen && model.selectedTaskID == p[4].id && seen.id == p[4].id,
               "triage=\(model.isTriageOpen) selected=\(String(describing: model.selectedTaskID)) asked=\(String(describing: seen.id)) want=\(p[4].id)")

        // Delete and Space: reopen; the restored Someday probe is first, then p4.
        _ = await openTriage(model, .sort)
        depth = store.undoDepth
        key("\u{7F}", keyCode: 51)
        _ = await waitUntil { store.taskIncludingDeleted(p[3].id)?.deletedAt != nil }
        record("triage[C] Delete removes the card's task in one undo step with a pill",
               store.taskIncludingDeleted(p[3].id)?.deletedAt != nil && store.undoDepth == depth + 1 && pillMentions(p[3].title),
               "deleted=\(store.taskIncludingDeleted(p[3].id)?.deletedAt != nil) depth=\(store.undoDepth) was=\(depth)")
        depth = store.undoDepth
        key(" ", keyCode: 49)
        _ = await waitUntil { store.task(p[4].id)?.status == .done }
        let wantDone: KStatus = breakMode ? .todo : .done
        record("triage[C] Space completes the card's task in one undo step with a pill",
               store.task(p[4].id)?.status == wantDone && store.undoDepth == depth + 1 && pillMentions(p[4].title),
               "status=\(String(describing: store.task(p[4].id)?.status)) depth=\(store.undoDepth) was=\(depth)")
        // Tab skips the next two cards (p5, p6); the waiting probe is on the card: W releases it and stays.
        key("\t", keyCode: 48); await settle(250)
        key("\t", keyCode: 48); await settle(250)
        depth = store.undoDepth
        key("w")
        _ = await waitUntil { store.task(p[7].id)?.status != .waiting }
        record("triage[C] W on a task that is already waiting releases it in one undo step with a pill and keeps the card",
               store.task(p[7].id)?.status != .waiting && store.task(p[7].id)?.needsTriage == true && store.undoDepth == depth + 1
                   && pillMentions(p[7].title) && model.isTriageOpen,
               "status=\(String(describing: store.task(p[7].id)?.status)) depth=\(store.undoDepth) was=\(depth) open=\(model.isTriageOpen)")
        // Shift-T on a task already planned for tomorrow still counts as decided: it leaves the card.
        store.plan(p[7].id, day: today + 1)
        model.didMutate()
        key("T", modifiers: .shift)
        _ = await waitUntil { store.task(p[7].id)?.needsTriage == false }
        record("triage[C] Shift-T settles the card even when it is already planned for tomorrow",
               store.task(p[7].id)?.needsTriage == false && store.task(p[7].id)?.plannedDay == today + 1, "needsTriage=\(String(describing: store.task(p[7].id)?.needsTriage))")
        key("\u{1B}", keyCode: 53)
        _ = await waitUntil { !model.isTriageOpen }
        record("triage[C] Esc closes the card", !model.isTriageOpen, "open=\(model.isTriageOpen)")
        for t in p { store.softDeleteNoUndo(t.id) }
        model.pinnedFocusTaskID = nil
        model.didMutate()
    }

    // MARK: Sweep card

    private static func grammarOnSweepCard(_ model: AppModel, breakMode: Bool) async {
        let store = model.store
        let today = Day.today(calendar: KronosLocale.calendar)
        let oldest = store.create(title: "Sweep grammar oldest")
        let next = store.create(title: "Sweep grammar next")
        for id in [oldest.id, next.id] { store.updateNoUndo(id) { $0.needsTriage = false } }
        store.updateNoUndo(oldest.id) { $0.updatedAt = Date().addingTimeInterval(-86_400 * 90) }
        store.updateNoUndo(next.id) { $0.updatedAt = Date().addingTimeInterval(-86_400 * 89) }
        // A task selected in the list underneath: keys the card does not use must not reach it.
        let bystander = store.create(title: "Sweep grammar bystander")
        store.updateNoUndo(bystander.id) { $0.needsTriage = false }
        model.didMutate()
        model.selectedTaskID = bystander.id
        let opened = await openTriage(model, .sweep)
        record("triage[C] sweep opens", opened, "opened=\(opened)")
        var depth = store.undoDepth
        key("T", modifiers: .shift); key("h"); key("w"); key("3"); key("f"); await settle(300)
        record("triage[C] Shift-T, H, W, 3 and F mean nothing on the sweep card and do not reach the list underneath",
               store.undoDepth == depth && store.task(oldest.id)?.plannedDay == nil && store.task(oldest.id)?.status == .todo
                   && store.task(bystander.id)?.plannedDay == nil && store.task(bystander.id)?.priority == KPriority.none && model.pinnedFocusTaskID != bystander.id,
               "depth=\(store.undoDepth) was=\(depth) planned=\(String(describing: store.task(oldest.id)?.plannedDay)) status=\(String(describing: store.task(oldest.id)?.status)) bystanderPlanned=\(String(describing: store.task(bystander.id)?.plannedDay)) pinned=\(String(describing: model.pinnedFocusTaskID))")
        key("t")
        _ = await waitUntil { store.task(oldest.id)?.plannedDay == today }
        let wantDay = breakMode ? today + 1 : today
        record("triage[C] T plans the sweep card for today in one undo step", store.task(oldest.id)?.plannedDay == wantDay && store.undoDepth == depth + 1,
               "planned=\(String(describing: store.task(oldest.id)?.plannedDay)) depth=\(store.undoDepth) was=\(depth)")
        depth = store.undoDepth
        key(" ", keyCode: 49)
        _ = await waitUntil { store.task(next.id)?.status == .done }
        record("triage[C] Space completes the next sweep card", store.task(next.id)?.status == .done && store.undoDepth == depth + 1,
               "status=\(String(describing: store.task(next.id)?.status)) depth=\(store.undoDepth) was=\(depth)")
        key("\u{1B}", keyCode: 53)
        _ = await waitUntil { !model.isTriageOpen }
        for id in [oldest.id, next.id, bystander.id] { store.softDeleteNoUndo(id) }
        model.selectedTaskID = nil
        model.didMutate()
    }

    // MARK: "AI is not set up"

    private static func aiSetupKey(_ model: AppModel, breakMode: Bool) async {
        let store = model.store
        let task = store.create(title: "AI setup probe")
        store.updateNoUndo(task.id) { $0.createdAt = Date(timeIntervalSince1970: 900_000) }
        model.didMutate()
        let savedRouter = model.ai
        let savedTab = KronosEnv.defaults.string(forKey: TriageSettingsLink.lastTabKey)
        KronosEnv.defaults.removeObject(forKey: TriageSettingsLink.lastTabKey)
        model.ai = NoKeyRouter()
        let windowsBefore = Set(NSApp.windows.map { ObjectIdentifier($0) })
        let seen = Seen()
        let token = NotificationCenter.default.addObserver(forName: .kronosSettingsRequested, object: nil, queue: .main) { note in
            seen.tab = note.userInfo?["tab"] as? String
        }
        _ = await openTriage(model, .sort)
        let shown = await waitUntil(timeout: 5) { UITestAnchors.frames["triage.card.ai.setup"] != nil }
        let frame = UITestAnchors.frames["triage.card.ai.setup"] ?? .zero
        record("triage[C] AI is not set up shows as a control with a 24 pt hit area",
               shown && frame.width >= Metrics.minHit && frame.height >= Metrics.minHit,
               "shown=\(shown) frame=\(Int(frame.width))x\(Int(frame.height))")
        key("r")
        _ = await waitUntil(timeout: 3) { seen.tab != nil }
        let stored = KronosEnv.defaults.string(forKey: TriageSettingsLink.lastTabKey)
        let wantTab = breakMode ? "general" : "ai"
        record("triage[C] R on the AI setup line opens Settings on the AI tab",
               seen.tab == wantTab && stored == wantTab, "requested=\(String(describing: seen.tab)) stored=\(String(describing: stored))")
        NotificationCenter.default.removeObserver(token)
        // Put the run back the way it was: the Settings window the request opened goes away.
        for w in NSApp.windows where !windowsBefore.contains(ObjectIdentifier(w)) { w.orderOut(nil) }
        if let savedTab { KronosEnv.defaults.set(savedTab, forKey: TriageSettingsLink.lastTabKey) } else { KronosEnv.defaults.removeObject(forKey: TriageSettingsLink.lastTabKey) }
        model.ai = savedRouter
        model.isTriageOpen = false
        _ = await ensureKey()
        store.softDeleteNoUndo(task.id)
        model.didMutate()
    }
}
#endif
