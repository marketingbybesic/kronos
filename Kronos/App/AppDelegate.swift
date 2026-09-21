import AppKit
import SwiftData
import KronosCore

/// Per-step launch timing, written to a file only when asked for (`KRONOS_LAUNCH_TRACE=1`):
/// zero cost otherwise, since every call is a single `Bool` env check before any `Date()` or
/// file I/O happens. Used by a launch-time benchmark script to find where launch time goes at
/// a realistic store shape and at scale, without adding any always-on overhead.
@MainActor
enum LaunchTrace {
    private static let enabled = ProcessInfo.processInfo.environment["KRONOS_LAUNCH_TRACE"] == "1"
    private static let start = Date()
    private static var lines: [String] = []

    static func mark(_ step: String) {
        guard enabled else { return }
        lines.append("\(step)\t\(Date().timeIntervalSince(start) * 1000)")
    }

    /// Flushed once, after the first frame is up — nothing before that point is worth
    /// blocking launch to write to disk.
    static func flush() {
        guard enabled, !lines.isEmpty else { return }
        let url = KronosStore.containerDirectory().appendingPathComponent("launch-trace.tsv")
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        lines.removeAll()
    }
}

/// Owns the one `TaskStore` (the only ModelContainer in the process), the shared `AppModel`,
/// and the menu-bar / quick-add controllers.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate!

    let store: TaskStore
    let model: AppModel
    let menuBarOrdo: MenuBarOrdoController
    let quickAdd: QuickAddController

    /// Owns the MCP listener: Settings toggles it live and reads its real port / last error.
    private(set) lazy var mcpLive = MCPLiveController(store: store, ranking: RankingEngine())
    private var blockTimer: Timer?
    private var spotlightIndexer: SpotlightIndexer?
    /// Fills empty fields of new tasks from the rest of the list (Settings > Coach).
    private(set) var autoTriage: AutoTriage?
    private var dayChangeCoordinator: DayChangeCoordinator?
    private var dayChangeObservers: DayChangeObservers?
    private var nightSweep: NightSweep?
    private var externalChangeObserver: NSObjectProtocol?
    private var firstFrameObserver: NSObjectProtocol?

    override init() {
        do {
            // Snapshot runs use an in-memory store so they never open the real one. The harness
            // itself is compiled out of Release (it exists to drive hand-testing, not to ship),
            // so a Release build is never asked to run in-memory this way.
            #if !RELEASE
            let inMemory = SnapshotHarness.isRequested
            #else
            let inMemory = false
            #endif
            self.store = try TaskStore(inMemory: inMemory)
        } catch {
            fatalError("KronosContainer: \(error)")
        }
        self.model = AppModel(store: store)
        self.menuBarOrdo = MenuBarOrdoController(model: model)
        self.quickAdd = QuickAddController(model: model)
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchTrace.mark("applicationDidFinishLaunching")
        #if !RELEASE
        if SnapshotHarness.isRequested { SnapshotHarness.run(store: store); return }
        #endif
        // Density/text size: read once before the first window, since the design system
        // cannot import KronosCore to read CoachSettings itself. A live change in Settings
        // updates the stored value; applying the new scale needs a relaunch, same as language
        // (Settings > Appearance reuses that "Relaunch to apply" caption).
        DSScale.apply(density: model.coach.settings.density, textSize: model.coach.settings.textSize)
        LaunchTrace.mark("DSScale.apply")
        seedIfEmpty()
        LaunchTrace.mark("seedIfEmpty")
        // One-time catch-up for open undated `.todo` tasks created before the automatic status
        // rule existed, so they still surface in Someday instead of sitting invisible.
        // Idempotent (marker file), backs up first, skips on backup failure.
        _ = UndatedSomedayMigration.runIfNeeded(store: store)
        LaunchTrace.mark("UndatedSomedayMigration")
        // A second, independent path to every Option-modified window-scope menu command
        // (Opt-Cmd-T Triage foremost), matched by physical key code so it is immune to whatever
        // SwiftUI's `.keyboardShortcut` menu-equivalent localization is doing. Installed for
        // both the real launch and the live UI test below, so ui-test.mjs's own synthetic
        // chords get a second chance to be seen too.
        OptionChordMonitor.install()
        LaunchTrace.mark("OptionChordMonitor.install")
        // The live UI test runs beside a normal running app: no menu-bar item, no global
        // hotkeys, no Keychain, no Spotlight, no permission window. It only drives its own
        // window.
        #if !RELEASE
        if LiveUITest.isRequested {
            DemoData.load(into: model.store)
            model.didMutate()
            AIWiring.configure(model)
            LiveUITest.run(model: model)
            return
        }
        #endif
        menuBarOrdo.install()
        LaunchTrace.mark("menuBarOrdo.install")
        offerPermissionsOnce()
        LaunchTrace.mark("offerPermissionsOnce")
        quickAdd.start()
        LaunchTrace.mark("quickAdd.start")
        AIWiring.configure(model)
        AIWiring.observe(model)
        LaunchTrace.mark("AIWiring")
        let triage = AutoTriage(model: model)
        triage.start()
        autoTriage = triage
        LaunchTrace.mark("AutoTriage.start")
        // The self-test never touches the Keychain: a fresh code identity raises a macOS dialog
        // nobody is there to answer, and the read blocks until it is.
        #if !RELEASE
        if LiveSelfTest.reportPath == nil { mcpLive.applyStoredEnabledState() }
        #else
        mcpLive.applyStoredEnabledState()
        #endif
        LaunchTrace.mark("mcpLive.applyStoredEnabledState")
        startDayChangeTracking()
        LaunchTrace.mark("startDayChangeTracking")
        BackupScheduler(store: store).runIfNeeded()
        LaunchTrace.mark("BackupScheduler.runIfNeeded")
        observeExternalChanges()
        observeCompletions()
        startBlockCoach()
        LaunchTrace.mark("observers+blockCoach")
        // First frame: `didUpdateNotification` fires once the window finishes its initial
        // layout and draw, whether or not the app is the active/frontmost app — unlike
        // `didBecomeMainNotification`, which a backgrounded launch (`open -g -n`, used by
        // launch-time benchmarks so a bench run never steals focus) may never post at all,
        // since a window only becomes "main" alongside app activation.
        // Everything after this point (Spotlight, Siri/Shortcuts registration, the self-test)
        // is real launch-path work but none of it is needed to show that frame, so it moves
        // here instead of running before it, so the user is not made to wait for it.
        // One-shot: `didUpdateNotification` is posted for every window on every pass of the
        // event loop, so the observer removes itself the first time it fires instead of being
        // called (and returning early) for the rest of the app's life.
        firstFrameObserver = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification,
                                                                     object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let token = self.firstFrameObserver else { return }
                NotificationCenter.default.removeObserver(token)
                self.firstFrameObserver = nil
                LaunchTrace.mark("firstFrame")
                LaunchTrace.flush()
                // Siri / Shortcuts / Spotlight (hermetic under snapshots; this path never runs
                // for them). Neither result is visible in the first frame, so both run after it.
                KronosIntents.bootstrap(model: self.model)
                self.spotlightIndexer = SpotlightIndexer.start(model: self.model)
                #if !RELEASE
                LiveSelfTest.run(model: self.model, autoTriage: self.autoTriage)
                #endif
            }
        }
    }

    /// The classic "what Kronos may use" window, shown once. It only LISTS: every system prompt
    /// still needs the user's own click inside it.
    private func offerPermissionsOnce() {
        let env = ProcessInfo.processInfo.environment
        guard env["KRONOS_SNAPSHOT"] == nil, env["KRONOS_STORE_DIR"] == nil, env["KRONOS_SELFTEST"] == nil else { return }
        let key = "kronos.permissions.shownOnce"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [model] in
            PermissionsWindowController.show(model: model, mcpStatus: self.mcpLive)
        }
    }

    /// First launch: import the Linear seed if present and the store is empty.
    private func seedIfEmpty() {
        guard store.allTasks().isEmpty else { return }
        guard let data = try? Data(contentsOf: KronosStore.seedURL()) else { return }
        _ = try? JSONImporter(store: store).importJSON(data)
        model.didMutate()
    }

    // MARK: MCP (INTEGRATION.md "App target wiring")

    // The listener lives in `mcpLive` (Kronos/MCP/MCPLiveController.swift): it reads the token off
    // the main thread and never starts an unsecured server.

    // MARK: Day change (INTEGRATION.md "App target wiring")

    private func startDayChangeTracking() {
        let coordinator = DayChangeCoordinator(clock: SystemClock(),
                                                scheduler: TimerDayChangeScheduler(),
                                                defaults: UserDefaults.standard)
        let observers = DayChangeObservers(coordinator: coordinator)
        let sweep = NightSweep(store: store, clock: SystemClock(), defaults: UserDefaults.standard)
        dayChangeCoordinator = coordinator
        dayChangeObservers = observers
        nightSweep = sweep
        coordinator.start()

        NotificationCenter.default.addObserver(forName: .kronosDayDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.nightSweep?.runIfNeeded()
                _ = BackupScheduler(store: self.store).runIfNeeded()
                self.model.didMutate()
            }
        }
    }

    /// The block coach looks at the calendar on launch, on wake and once a minute. It never asks
    /// for calendar access itself (only Settings does) and stays silent without it.
    private func startBlockCoach() {
        refreshBlockCoach()
        blockTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshBlockCoach() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshBlockCoach() }
        }
    }

    private func refreshBlockCoach() {
        let coach = model.coach
        Task { await coach?.refreshBlocks() }
    }

    /// One place plays the completion cues; Core announces only completions made by a person.
    private func observeCompletions() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: .kronosTaskDidComplete, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { KronosSounds.play(.task) }
        }
        nc.addObserver(forName: .kronosSubtaskDidComplete, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { KronosSounds.play(.subtask) }
        }
    }

    /// MCP writes land on a background connection; refresh every list once one completes.
    private func observeExternalChanges() {
        externalChangeObserver = NotificationCenter.default.addObserver(
            forName: .kronosStoreDidChangeExternally, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.model.didMutate() }
        }
    }

    /// A Spotlight result was clicked: open that task.
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard let id = SpotlightIndexer.taskID(from: userActivity) else { return false }
        model.scope = .all
        model.selectedTaskID = id
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        mcpLive.stop()
        model.persist()
    }
}
