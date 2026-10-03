// Live steps for Sweep and five-card sittings. Run alone with `--only group:B2-TRIAGE`.
#if !RELEASE
import AppKit
import KronosCore

@MainActor
extension LiveUITest {
    static func b2TriageSteps(_ model: AppModel) async {
        await sweepFromPalette(model)
        await fiveCardSitting(model)
    }

    /// The palette opens Sweep on the quietest task; Y moves it to Someday (one undo step with a
    /// pill), Return keeps the next one (stamps it, changes nothing else).
    private static func sweepFromPalette(_ model: AppModel) async {
        let store = model.store
        let breakMode = ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil
        let oldest = store.create(title: "Sweep probe oldest")
        let second = store.create(title: "Sweep probe second")
        let stale = Date().addingTimeInterval(-86_400 * 60)
        // Two calls: a store write that changes a tracked field stamps updatedAt itself, so the
        // age is set last, alone.
        for id in [oldest.id, second.id] { store.updateNoUndo(id) { $0.needsTriage = false } }
        store.updateNoUndo(oldest.id) { $0.updatedAt = stale.addingTimeInterval(-3_600) }
        store.updateNoUndo(second.id) { $0.updatedAt = stale }
        model.didMutate()
        if model.isTriageOpen { model.isTriageOpen = false; await settle(300) }

        window.makeKeyAndOrderFront(nil)
        model.isPaletteOpen = true
        await settle(500)
        for ch in "sweep old" { key(String(ch)); try? await Task.sleep(for: .milliseconds(30)) }
        await settle(400)
        key("\r", keyCode: 36)
        _ = await waitUntil(timeout: 4) { UITestAnchors.frames["sweep.card.age"] != nil }
        await settle(300)
        record("palette Sweep opens the sweep card", model.isTriageOpen && UITestAnchors.frames["sweep.card.age"] != nil,
               "open=\(model.isTriageOpen) age=\(UITestAnchors.frames["sweep.card.age"] != nil)")

        let depth = store.undoDepth
        key("y")
        _ = await waitUntil { store.task(oldest.id)?.status == .someday }
        let wantStatus: KStatus = breakMode ? .todo : .someday
        record("Sweep Y moves the quietest task to Someday in one undo step with a pill",
               store.task(oldest.id)?.status == wantStatus && store.undoDepth == depth + 1 && UndoToastCenter.shared.current != nil,
               "status=\(String(describing: store.task(oldest.id)?.status)) depth=\(store.undoDepth) was=\(depth)")

        let before = store.task(second.id)?.updatedAt ?? stale
        let depthBeforeKeep = store.undoDepth
        key("\r", keyCode: 36)
        await settle(500)
        let kept = store.task(second.id)
        record("Sweep Return keeps the next task: stamped, status unchanged, no undo step",
               (kept?.updatedAt ?? before) > before.addingTimeInterval(86_400) && kept?.status == .todo && store.undoDepth == depthBeforeKeep,
               "status=\(String(describing: kept?.status)) stamped=\((kept?.updatedAt ?? before) > before) depth=\(store.undoDepth) was=\(depthBeforeKeep)")

        key("\u{1B}", keyCode: 53)
        _ = await waitUntil { !model.isTriageOpen }
        record("Sweep Esc closes", !model.isTriageOpen, "open=\(model.isTriageOpen)")
    }

    /// Five Tabs end the sitting: the end panel shows and Return starts the next one.
    private static func fiveCardSitting(_ model: AppModel) async {
        let store = model.store
        for i in 0..<8 { _ = store.create(title: "Sitting probe \(i)") }
        model.didMutate()
        TriageLaunch.shared.request(.sort)
        model.isTriageOpen = true
        _ = await waitUntil(timeout: 4) { UITestAnchors.frames["triage.card.progress"] != nil }
        await settle(300)
        for _ in 0..<5 { key("\t", keyCode: 48); await settle(250) }
        let over = await waitUntil(timeout: 3) { UITestAnchors.frames["triage.card.sessiondone"] != nil }
        record("five skipped cards end the sitting with the continue panel", over, "panel=\(over)")
        key("\r", keyCode: 36)
        let next = await waitUntil(timeout: 3) { UITestAnchors.frames["triage.card.sessiondone"] == nil && UITestAnchors.frames["triage.card.progress"] != nil }
        record("Return on the end panel starts the next sitting", next, "next=\(next)")
        key("\u{1B}", keyCode: 53)
        _ = await waitUntil { !model.isTriageOpen }
    }
}
#endif
