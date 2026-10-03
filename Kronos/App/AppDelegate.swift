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
    /// Set when the store would not open (ReadableLaunchError.swift): the app then runs on an empty in-memory
    /// store behind the error window and skips every other launch step.
    let launchFailure: LaunchFailure?
    private var servicesProvider: ServicesProvider?
    /// `.login` when the system started Kronos as a login item: no window, no welcome; the menu bar
    /// item is the whole launch. Hermetic runs are never a login launch.
    private(set) var launchKind: LaunchKind = .normal

    /// Owns the MCP listener: Settings toggles it live and reads its real port / last error.
    let mcpBackground = MCPBackgroundLaunch()
    private(set) lazy var mcpLive = MCPLiveController(store: store, ranking: RankingEngine())
    private var blockTimer: Timer?
    private var spotlightIndexer: SpotlightIndexer?
    /// Fills empty fields of new tasks from the rest of the list (Settings > Coach).
    private(set) var autoTriage: AutoTriage?
    private var dayChangeCoordinator: DayChangeCoordinator?
    private var dayChangeObservers: DayChangeObservers?
    private var nightSweep: NightSweep?
    private var snapshotFollower: SnapshotFollower?
    private var taskCompletionObserver: NSObjectProtocol?
    private var externalChangeObserver: NSObjectProtocol?
    private var firstFrameObserver: NSObjectProtocol?

    override init() {
        // One Kronos per store directory. A second launch on the same directory hands over to the
        // first and exits before it can open the store. A different directory (live test, hand
        // test) has its own lock and coexists. Snapshot runs use an in-memory store: no lock.
        if !KronosEnv.isSnapshot, !SingleInstanceLock.acquire(at: KronosEnv.lockURL, keep: true) {
            SingleInstanceLock.activateRunningHolder(at: KronosEnv.lockURL)
            FileHandle.standardError.write(Data("Kronos: already open on this store; handing over to the running instance\n".utf8))
            exit(0)
        }
        var failure: LaunchFailure?
        let opened: TaskStore
        do {
            // Snapshot runs use an in-memory store so they never open the real one. The harness
            // itself is compiled out of Release (it exists to drive hand-testing, not to ship),
            // so a Release build is never asked to run in-memory this way.
            #if !RELEASE
            let inMemory = SnapshotHarness.isRequested
            #else
            let inMemory = false
            #endif
            // Subtasks became child tasks: copy the store files aside BEFORE opening (the open
            // itself adds the new columns), then convert the old step rows once, before any
            // window or controller reads the store. A failed or incomplete copy is removed and
            // queues a notice; the conversion does not run this launch (no marker), so data is
            // never converted without a backup. The notice is shown by the next UI launch.
            var backup = SubtaskToTaskMigration.BackupResult.notNeeded
            if !inMemory { backup = SubtaskToTaskMigration.backupStoreFilesIfNeeded() }
            let candidate = try TaskStore(inMemory: inMemory)
            if !inMemory {
                // A store a newer build wrote stays untouched: no migration, no write; the readable
                // window explains it. Otherwise the recorded minimum schema version is raised.
                if case .readOnly(let requires) = StoreOpenGuard.apply(to: candidate, kvs: StoreOpenGuard.liveKVS()) {
                    throw StoreTooNewError(build: SchemaGuard.currentBuildVersion, requires: requires)
                }
                SubtaskToTaskMigration.runIfNeeded(store: candidate, backup: backup)
            }
            opened = candidate
        } catch {
            // Copy the store aside first, then show a readable window (applicationDidFinishLaunching).
            failure = LaunchFailure.capture(error)
            // An in-memory store always opens; it only lets init finish and is never written to disk.
            opened = try! TaskStore(inMemory: true)
        }
        self.store = opened
        self.launchFailure = failure
        self.model = AppModel(store: store)
        self.menuBarOrdo = MenuBarOrdoController(model: model)
        self.quickAdd = QuickAddController(model: model)
        super.init()
        AppDelegate.shared = self
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        registerURLHandler()   // DockMenu.swift: before launch ends, so a cold kronos:// URL is not lost
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchTrace.mark("applicationDidFinishLaunching")
        if let failure = launchFailure { LaunchErrorWindow.show(failure); return }
        #if !RELEASE
        if SnapshotHarness.isRequested { SnapshotHarness.run(store: store); return }
        #endif
        // Density/text size: read once before the first window, since the design system
        // cannot import KronosCore to read CoachSettings itself. A live change in Settings
        // updates the stored value; applying the new scale needs a relaunch, same as language
        // (Settings > Appearance reuses that "Relaunch to apply" caption).
        DSScale.apply(density: model.coach.settings.density, textSize: model.coach.settings.textSize)
        LaunchTrace.mark("DSScale.apply")
        launchKind = LaunchKind.detect(launchedAsLoginItem: LaunchKind.currentEventIsLoginItem(),
                                       isHermetic: KronosEnv.isHermetic)
        KronosSounds.preload()
        // Stamps new device-local links with this device (per-device id in the scratch defaults of a hermetic run).
        DeviceOrigin.configureLive(defaults: KronosEnv.defaults)
        seedIfEmpty()
        LaunchTrace.mark("seedIfEmpty")
        // One-time catch-up for open undated `.todo` tasks created before the automatic status
        // rule existed, so they still surface in Someday instead of sitting invisible.
        // Idempotent (marker file), backs up first, skips on backup failure.
        _ = UndatedSomedayMigration.runIfNeeded(store: store)
        LaunchTrace.mark("UndatedSomedayMigration")
        TaskStore.stripCorruptContextLinkLines(store: store)
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
           installDataSafetyObservers()
           LiveUITest.run(model: model)
           return
       }
        // Kronos Demo build: auto-load demo data on first launch when the store is empty.
        // Compile-time flag -DKRONOS_DEMO_AUTOLOAD set by scripts/build-demo.sh.
        #if KRONOS_DEMO_AUTOLOAD
        if model.store.allTasks().isEmpty {
            DemoData.load(into: model.store)
            model.didMutate()
        }
        #endif
       #endif
       applyLaunchScope()
       menuBarOrdo.install()
        LaunchTrace.mark("menuBarOrdo.install")
        if launchKind == .normal { offerWelcomeOnce() }
        LaunchTrace.mark("offerWelcomeOnce")
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
        MCPEndpointFile.removeLegacy()   // ~/.kronos-mcp.json held the bearer token world-readable
        mcpBackground.begin()
        showSubtaskBackupNoticeIfQueued()
        startDayChangeTracking()
        LaunchTrace.mark("startDayChangeTracking")
        installDataSafetyObservers()
        let scheduler = BackupScheduler(store: store)
        scheduler.runIfNeeded()
        scheduler.runRolling(force: false)
        LaunchTrace.mark("BackupScheduler.runIfNeeded")
        observeExternalChanges()
        observeCompletions()
        startBlockCoach()
        // The Snapshot writer: one write now, then after every model change (follows version and list head).
        let follower = SnapshotFollower(model: model)
        follower.start()
        snapshotFollower = follower
        // Opt-in block start notifications (off until the person turns them on in Settings).
        BlockStartNotifications.shared.start(model: model)
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
                if self.launchKind == .login { self.hideWindowsForLoginLaunch() }
                // Siri / Shortcuts / Spotlight (hermetic under snapshots; this path never runs
                // for them). Neither result is visible in the first frame, so both run after it.
                KronosIntents.bootstrap(model: self.model)
                // Services menu (NSServices in project.yml) and any kronos:// URL that arrived during launch.
                let provider = ServicesProvider(model: self.model)
                self.servicesProvider = provider
                NSApp.servicesProvider = provider
                NSUpdateDynamicServices()
                URLSchemeRouter.markReady(model: self.model)
                self.spotlightIndexer = SpotlightIndexer.start(model: self.model)
                #if !RELEASE
                LiveSelfTest.run(model: self.model, autoTriage: self.autoTriage)
                #endif
            }
        }
    }

    /// One-time notice when the pre-migration safety copy failed (nothing was converted, the next
    /// launch retries). A hidden --mcp-background launch has no UI: the notice stays queued on
    /// disk for the next normal launch.
    private func showSubtaskBackupNoticeIfQueued() {
        guard !MCPBackgroundLaunch.requested,
              let notice = SubtaskToTaskMigration.takePendingNotice() else { return }
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "app.migration.backup_failed.title")
            alert.informativeText = String(format: String(localized: "app.migration.backup_failed.body"),
                                           notice.reason, notice.folder)
            alert.runModal()   // AppKit supplies the localised default "OK" button
        }
    }

    /// First-run tour, shown once, before Permissions. An existing user who already saw
    /// Permissions (its own `kronos.permissions.shownOnce` flag already true) still sees the
    /// tour once — it is new to them — but does not see Permissions a second time.
    private func offerWelcomeOnce() {
        let env = ProcessInfo.processInfo.environment
        let welcomeKey = "kronos.welcome.shownOnce"
        let permissionsKey = "kronos.permissions.shownOnce"
        let decision = WelcomeGate.decide(env: env,
                                           welcomeShown: KronosEnv.defaults.bool(forKey: welcomeKey),
                                           permissionsShown: KronosEnv.defaults.bool(forKey: permissionsKey))
        // Permissions wait until the tour's basics are done (OnboardingLogic): asking on top of
        // the very first step is the worst moment. The closure also serves a tour started earlier.
        OnboardingCenter.shared.offerPermissions = { [model, mcpLive] in
            KronosEnv.defaults.set(true, forKey: permissionsKey)
            PermissionsWindowController.show(model: model, mcpStatus: mcpLive)
        }
        guard decision.showWelcome else { return }
        KronosEnv.defaults.set(true, forKey: welcomeKey)
        // One intro screen (what Kronos is), then the Learn Kronos card on the list, tried at the
        // user's own pace (Kronos/Welcome/Onboarding*.swift). Closing the intro counts the same.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [model] in
            // "Show me around" runs the guided tour over the real window (TourOverlay);
            // "Later" or closing still leaves the Learn Kronos card, and Help reopens both.
            OnboardingIntroController.show(onStart: {
                                               OnboardingCenter.shared.start(model: model)
                                               TourCenter.shared.start(model: model)
                                           },
                                           onLater: { OnboardingCenter.shared.start(model: model) })
        }
    }

    /// First launch: import the Linear seed if present and the store is empty.
    /// Not part of the public flavour: that build has no Linear import path at all.
    private func seedIfEmpty() {
        #if !KRONOS_PUBLIC
        guard LaunchSeeding.shouldSeed(storeIsEmpty: store.allTasks().isEmpty) else { return }
        guard let data = try? Data(contentsOf: KronosStore.seedURL()) else { return }
        _ = try? JSONImporter(store: store).importJSON(data)
        model.didMutate()
        #endif
    }

    // MARK: MCP (INTEGRATION.md "App target wiring")

    // The listener lives in `mcpLive` (Kronos/MCP/MCPLiveController.swift): it reads the token off
    // the main thread and never starts an unsecured server.

    // MARK: Day change (INTEGRATION.md "App target wiring")

    private func startDayChangeTracking() {
        let coordinator = DayChangeCoordinator(clock: SystemClock(),
                                                scheduler: TimerDayChangeScheduler(),
                                                defaults: KronosEnv.defaults)
        let observers = DayChangeObservers(coordinator: coordinator)
        let sweep = NightSweep(store: store, clock: SystemClock(), defaults: KronosEnv.defaults)
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
        taskCompletionObserver = CompletionSound.observe(store: store)
        nc.addObserver(forName: .kronosSubtaskDidComplete, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                let id = note.userInfo?["subtaskID"] as? UUID
                KronosSounds.play(Self.completionCue(forSubtask: id, store: self?.store))
            }
        }
    }

    /// The step cue, or the parent cue when this step was the last open one of a parent: finishing a
    /// parent is a bigger moment than finishing one step. Unknown ids fall back to the step cue.
    static func completionCue(forSubtask id: UUID?, store: TaskStore?) -> KronosSounds.Cue {
        guard let id, let parent = store?.taskIncludingDeleted(id)?.parent else { return .subtask }
        let children = parent.orderedChildren
        return !children.isEmpty && children.allSatisfy({ $0.status == .done }) ? .parent : .subtask
    }

    /// MCP writes land on a background connection; refresh every list once one completes.
    private func observeExternalChanges() {
        externalChangeObserver = NotificationCenter.default.addObserver(
            forName: .kronosStoreDidChangeExternally, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.model.didMutate() }
        }
    }

    /// F1: open on the list that has something to do and select its first row, so the inspector
    /// shows the first move at once. Hermetic runs keep `.inbox` with nothing selected.
    private func applyLaunchScope() {
        guard !LaunchScope.isHermetic(ProcessInfo.processInfo.environment) else { return }
        switch AppModel.launchScopeChoice(store: model.store, hermetic: false, today: Day.today()) {
        case .inbox: model.scope = .inbox
        case .today: model.scope = .today
        case .all: model.scope = .all
        }
        model.selectedTaskID = ListContext(model: model).rows.first { KStatus.open.contains($0.status) }?.id
    }

    /// A Spotlight result was clicked: open that task.
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        switch SpotlightIndexer.target(from: userActivity) {
        case .task(let id):
            model.openTaskByID(id)
        case .project(let id):
            guard model.store.allProjects(includeArchived: true).contains(where: { $0.id == id }) else { return false }
            model.scope = .project(id)
        case nil:
            return false
        }
        bringForward()
        return true
    }

    /// Kronos lives in the menu bar too, so closing the window (or hiding it for
    /// --mcp-background) must not quit the app: SwiftUI's default is to terminate when the last
    /// window closes, which killed every background launch within a second.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Dock click while the window is hidden (--mcp-background) brings it back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, launchKind == .login { bringForward(); return false }
        return mcpBackground.restore() ? false : true
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard launchFailure == nil else { return }
        // Order matters: drafts first (the inspector commits typed fields), then the save, then the
        // rolling backup, which copies what is on disk.
        NotificationCenter.default.post(name: .kronosFlushDrafts, object: nil)
        saveStoreNow()
        mcpLive.stop()
        model.persist()
        BackupScheduler(store: store).runRolling(force: true)
    }

    // MARK: Data safety (drafts, save, rolling backup, save-failure notice)

    private var resignObserver: NSObjectProtocol?
    private var saveFailedObserver: NSObjectProtocol?
    /// Shown at most once while a notice is up; Core posts once per burst of failures.
    let saveFailureNotice = SaveFailureNotice()

    /// Resign-active: flush typed drafts, save, retake the rolling backup. Also the one place that
    /// shows the calm notice when a save fails. Observers are synchronous (no queue), so the order
    /// flush -> save -> backup holds.
    func installDataSafetyObservers() {
        guard resignObserver == nil else { return }
        let nc = NotificationCenter.default
        resignObserver = nc.addObserver(forName: NSApplication.willResignActiveNotification,
                                        object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushSaveAndBackUp() }
        }
        saveFailedObserver = nc.addObserver(forName: .kronosSaveFailed, object: nil, queue: nil) { [weak self] _ in
            // A save can fail on a background connection: hop to the main actor either way.
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.saveFailureNotice.report() }
            } else {
                Task { @MainActor in self?.saveFailureNotice.report() }
            }
        }
    }

    func flushSaveAndBackUp() {
        guard launchFailure == nil else { return }
        NotificationCenter.default.post(name: .kronosFlushDrafts, object: nil)
        saveStoreNow()
        BackupScheduler(store: store).runRolling(force: false)
    }

    /// Saves pending changes. A failure keeps the changes in memory, writes a readable copy next to
    /// the backups and raises `.kronosSaveFailed` (one notice, see `SaveFailureNotice`).
    @discardableResult
    func saveStoreNow() -> Bool {
        let context = store.context
        context.processPendingChanges()
        guard context.hasChanges else { return true }
        do {
            try context.save()
            return true
        } catch {
            let dir = BackupScheduler.defaultDirectory
            let url = dir.appendingPathComponent("emergency-\(BackupFileStamp.utc()).json")
            try? BackupFile.write(JSONExporter(store: store).makeEnvelope(), to: url)
            NotificationCenter.default.post(name: .kronosSaveFailed, object: nil,
                                            userInfo: ["error": String(describing: error)])
            return false
        }
    }
}

// MARK: - Single instance

/// One Kronos per store directory: an exclusive, non-blocking `flock` on `store.lock` next to the
/// store, held for the life of the process (the kernel drops it on exit or crash, so there is
/// never a stale lock to clean up). The holder's pid is written into the file so a second launch
/// can bring the first one forward.
enum SingleInstanceLock {
    private static var held: Int32 = -1

    /// true = this process may go on. `keep` holds the lock until exit; without it the lock is
    /// taken and released at once (a probe: "would a second instance be refused?").
    /// A location that cannot be opened never blocks the app.
    static func acquire(at url: URL, keep: Bool) -> Bool {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return true }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return false }
        guard keep else { flock(fd, LOCK_UN); close(fd); return true }
        held = fd
        ftruncate(fd, 0)
        let pid = Array("\(getpid())\n".utf8)
        _ = pid.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        return true
    }

    /// Brings the instance that holds the lock forward (best effort; a hidden background launch has
    /// no window to show, a Dock click restores it).
    static func activateRunningHolder(at url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.activate()
    }
}

// MARK: - Save failure notice

/// The calm notice for a failed save: one sheet on the front window, not a stack of them. While
/// it is up, further `.kronosSaveFailed` posts are ignored; once dismissed the next one shows
/// again. `presenter` is replaceable so a test can count notices without opening a dialog.
@MainActor
final class SaveFailureNotice {
    private(set) var isShowing = false
    private(set) var shownCount = 0
    var presenter: (_ done: @escaping @MainActor () -> Void) -> Void = SaveFailureNotice.presentAlert

    func report() {
        guard !isShowing else { return }
        isShowing = true
        shownCount += 1
        presenter { [weak self] in self?.isShowing = false }
    }

    /// A hidden background launch and hermetic runs have nobody to read it: nothing is shown.
    static func presentAlert(done: @escaping @MainActor () -> Void) {
        guard !MCPBackgroundLaunch.requested, !KronosEnv.isHermetic else { done(); return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "app.save_failed.title")
        alert.informativeText = String(localized: "app.save_failed.body")
        alert.addButton(withTitle: String(localized: "common.close"))
        alert.addButton(withTitle: String(localized: "app.save_failed.folder"))
        let finish: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertSecondButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([BackupScheduler.defaultDirectory])
            }
            done()
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window) { response in MainActor.assumeIsolated { finish(response) } }
        } else {
            DispatchQueue.main.async { finish(alert.runModal()) }
        }
    }
}

enum BackupFileStamp {
    /// `20261002T091530Z`, for file names that must sort and never collide across time zones.
    static func utc(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }
}
