// Live steps for the tour's sample tasks, the permission explainer and the Help welcome entry.
// Run alone with `--only group:C-ONBOARD`.
#if !RELEASE
import AppKit
import KronosCore

@MainActor
extension LiveUITest {
    static func cOnboardSteps(_ model: AppModel) async {
        await tourSampleLifecycle(model)
        await primerContinue(model)
        await helpWelcomeEntry(model)
    }

    private static func sampleTitles() -> [String] {
        TourSample.titleKeys.map { String(localized: String.LocalizationValue($0)) }
    }

    private static func samples(_ model: AppModel) -> [KTask] {
        let titles = sampleTitles()
        return model.store.allTasks().filter { titles.contains($0.title) }
    }

    /// The tour makes its sample tasks (forced here: the scratch store already has work), walks to
    /// the end with Return only, and nothing is left; Esc ends a second run the same way. Neither
    /// run touches the undo history.
    private static func tourSampleLifecycle(_ model: AppModel) async {
        let breakMode = ProcessInfo.processInfo.environment["KRONOS_UITEST_BREAK"] != nil
        let store = model.store
        let depth = store.undoDepth
        let before = samples(model).count

        TourCenter.shared.start(model: model, sample: true)
        _ = await waitUntil(timeout: 4) { samples(model).count == before + 2 }
        record("tour start makes two sample tasks", samples(model).count == before + 2 && TourCenter.shared.isRunning,
               "samples=\(samples(model).count) before=\(before) running=\(TourCenter.shared.isRunning)")
        record("sample tasks are not an undo step", store.undoDepth == depth, "depth=\(store.undoDepth) was=\(depth)")
        record("sample ids are remembered for a cut-short run",
               KronosEnv.defaults.string(forKey: TourSample.defaultsKey)?.split(separator: ",").count == 2, "")

        // With the Learn card on the list too, an empty-store tour shows every one of its 8 steps.
        OnboardingCenter.shared.setFixture(OnboardingState(startedAt: Date()))
        await ensureKey()
        _ = await waitUntil(timeout: 5) { TourCenter.shared.latestAvailable.count == TourAnchor.allCases.count - 1 }
        // The menu bar step has no part on screen and is always showable: 7 reported + it = 8.
        let progress = TourLogic.progress(index: 0, steps: TourSteps.all, available: TourCenter.shared.latestAvailable)
        record("the tour with its sample tasks can show all 8 steps",
               progress.total == 8 && TourSteps.all.count == 8,
               "total=\(progress.total) available=\(TourCenter.shared.latestAvailable.map(\.rawValue).sorted())")
        _ = await waitUntil(timeout: 4) { UITestAnchors.frames["tour.next"] != nil }
        if let f = UITestAnchors.frames["tour.next"] {
            record("tour Next button hit area is at least 24 pt", f.width >= Metrics.minHit && f.height >= Metrics.minHit,
                   "w=\(f.width) h=\(f.height)")
        }
        // Keyboard only: Return is the bubble's default action. Eight steps at most.
        var presses = 0
        while TourCenter.shared.isRunning, presses < 12 {
            key("\r", keyCode: 36)
            presses += 1
            await settle(450)
        }
        _ = await waitUntil(timeout: 3) { !TourCenter.shared.isRunning }
        OnboardingCenter.shared.setFixture(OnboardingState())
        let wantLeft = breakMode ? 2 : 0
        let left = samples(model).count - before
        record("Return through the whole tour ends it and removes both sample tasks",
               !TourCenter.shared.isRunning && left == wantLeft, "running=\(TourCenter.shared.isRunning) left=\(left) presses=\(presses)")
        record("removing the samples is not an undo step", store.undoDepth == depth, "depth=\(store.undoDepth) was=\(depth)")
        record("the stored sample ids are cleared", KronosEnv.defaults.string(forKey: TourSample.defaultsKey) == nil, "")

        TourCenter.shared.start(model: model, sample: true)
        _ = await waitUntil(timeout: 4) { samples(model).count == before + 2 }
        await ensureKey()
        _ = await waitUntil(timeout: 4) { UITestAnchors.frames["tour.next"] != nil }
        key("\u{1B}", keyCode: 53)
        _ = await waitUntil(timeout: 3) { !TourCenter.shared.isRunning }
        let leftAfterSkip = samples(model).count - before
        record("Esc ends the tour and removes both sample tasks too", !TourCenter.shared.isRunning && leftAfterSkip == 0,
               "running=\(TourCenter.shared.isRunning) left=\(leftAfterSkip)")
        record("a deleted sample is gone from every list", model.store.allTasks().allSatisfy { !sampleTitles().contains($0.title) || breakMode },
               "")
        // A run that was cut short (app quit) leaves its ids behind: the next start removes them.
        TourCenter.shared.start(model: model, sample: true)
        _ = await waitUntil(timeout: 4) { samples(model).count == before + 2 }
        let ids = samples(model).map(\.id.uuidString).joined(separator: ",")
        TourCenter.shared.end()
        let count = samples(model).count - before
        KronosEnv.defaults.set(ids, forKey: TourSample.defaultsKey)   // what a quit mid-tour would leave
        // The deleted rows come back only to prove the orphan sweep removes what its ids name.
        for t in model.store.allTasksIncludingDeleted() where ids.contains(t.id.uuidString) { model.store.restoreNoUndo(t.id) }
        TourCenter.shared.removeOrphanSample(model: model)
        let orphansLeft = samples(model).count - before
        record("an orphaned sample from a cut-short run is removed", count == 0 && orphansLeft == 0, "ended=\(count) orphans=\(orphansLeft)")
    }

    /// The explainer's button reads Continue; it opens the permission window only when pressed, and
    /// Esc leaves everything as it was.
    private static func primerContinue(_ model: AppModel) async {
        var continued = 0
        let main = window!
        PermissionsPrimerController.show(force: true, onContinue: { continued += 1 })
        _ = await waitUntil(timeout: 4) { PermissionsPrimerController.isOpen && UITestAnchors.frames["primer.continue"] != nil }
        let panel = NSApp.windows.first { $0.isVisible && $0.title == String(localized: "permissions.title") }
        record("permission explainer opens on its own window", panel != nil && PermissionsPrimerController.isOpen, "open=\(PermissionsPrimerController.isOpen)")
        if let f = UITestAnchors.frames["primer.continue"] {
            record("Continue hit area is at least 24 pt", f.width >= Metrics.minHit && f.height >= Metrics.minHit, "w=\(f.width) h=\(f.height)")
        }
        if let panel { window = panel; await ensureKey(panel) }
        await settle(500)
        key("\u{1B}", keyCode: 53)
        _ = await waitUntil(timeout: 3) { !PermissionsPrimerController.isOpen }
        record("Esc on the explainer closes it and continues nothing", !PermissionsPrimerController.isOpen && continued == 0,
               "open=\(PermissionsPrimerController.isOpen) continued=\(continued)")

        PermissionsPrimerController.show(force: true, onContinue: { continued += 1 })
        _ = await waitUntil(timeout: 4) { PermissionsPrimerController.isOpen && UITestAnchors.frames["primer.continue"] != nil }
        let again = NSApp.windows.first { $0.isVisible && $0.title == String(localized: "permissions.title") }
        if let again { window = again; await ensureKey(again) }
        await settle(500)   // the default button registers with the window a beat after it appears
        key("\r", keyCode: 36)
        _ = await waitUntil(timeout: 3) { !PermissionsPrimerController.isOpen }
        record("Return on the explainer continues once and closes it", !PermissionsPrimerController.isOpen && continued == 1,
               "open=\(PermissionsPrimerController.isOpen) continued=\(continued)")
        window = main
        await ensureKey(main)
    }

    /// Help > Welcome to Kronos… opens the one intro screen, and closing it starts nothing.
    private static func helpWelcomeEntry(_ model: AppModel) async {
        let main = window!
        let startedBefore = OnboardingCenter.shared.state.startedAt
        let title = String(localized: "welcome.title")
        OnboardingIntroController.showFromHelp()
        _ = await waitUntil(timeout: 4) { NSApp.windows.contains { $0.isVisible && $0.title == title } }
        let intro = NSApp.windows.first { $0.isVisible && $0.title == title }
        // The hosting view's ideal size is the 600 x 640 screen; the old pages were 560 x 520.
        let size = intro?.contentView?.fittingSize
        record("Help welcome opens the intro screen (600 x 640), not the old seven pages",
               intro != nil && size?.width == 600 && size?.height == 640,
               "size=\(String(describing: size))")
        intro?.close()
        _ = await waitUntil(timeout: 3) { !NSApp.windows.contains { $0.isVisible && $0.title == title } }
        record("closing the intro from Help starts nothing", OnboardingCenter.shared.state.startedAt == startedBefore
               && !TourCenter.shared.isRunning, "started=\(String(describing: OnboardingCenter.shared.state.startedAt))")
        record("the onboarding flags live in the hermetic defaults", KronosEnv.isHermetic, "hermetic=\(KronosEnv.isHermetic)")
        window = main
        await ensureKey(main)
    }
}
#endif
