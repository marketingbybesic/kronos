// Kronos/Notifications/BlockStartNotifications.swift
// The one opt-in notification channel: "Start: <first move>" when a calendar block that has a task
// linked to it begins, with Done, Not now and Open on the notification. Off until the person flips
// the switch in Settings; macOS permission is asked only from that switch, after one line of
// explanation. Never a notification for a due date.
//
// Hermetic runs (live test, snapshots, a store directory override) get a recording center: nothing
// is ever asked of, or sent to, the real system from a test.
import AppKit
import Observation
import KronosCore

@MainActor
@Observable
final class BlockStartNotifications {
    enum Stage: Equatable {
        case idle
        /// The switch was flipped and macOS has never been asked: show our own explanation first.
        case prePermission
        /// macOS said no (now or earlier): point at System Settings, keep the channel off.
        case refused
    }

    static let shared = BlockStartNotifications()
    static let enabledKey = "kronos.notify.blockstart.enabled"

    private(set) var isEnabled: Bool
    private(set) var stage: Stage = .idle

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let clock: KronosClock
    @ObservationIgnored private let makeCenter: @MainActor () -> NotificationCentering
    @ObservationIgnored private var storedCenter: NotificationCentering?
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var lastScheduled: [BlockStartRequest] = []
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var focusObserver: NSObjectProtocol?
    /// Test seam: blocks to plan against instead of the calendar's.
    @ObservationIgnored var blockSource: (@MainActor () -> [TimeBlockEntry])?

    init(defaults: UserDefaults = KronosEnv.defaults, clock: KronosClock = SystemClock(),
         makeCenter: @escaping @MainActor () -> NotificationCentering = BlockStartNotifications.defaultCenter) {
        self.defaults = defaults
        self.clock = clock
        self.makeCenter = makeCenter
        self.isEnabled = defaults.bool(forKey: Self.enabledKey)
        // Gate shots render the three states of the Settings section; nothing else reads this.
        if KronosEnv.isSnapshot, let stage = ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT_NOTIFY_STAGE"] {
            switch stage {
            case "pre": self.stage = .prePermission
            case "denied": self.stage = .refused
            case "on": self.isEnabled = true
            default: break
            }
        }
    }

    /// The real center only outside hermetic runs.
    static func defaultCenter() -> NotificationCentering {
        KronosEnv.isHermetic ? RecordingNotificationCenter() : SystemNotificationCenter()
    }

    /// Created on first use, so an app with the channel off never touches the system center.
    var center: NotificationCentering {
        if let storedCenter { return storedCenter }
        let created = makeCenter()
        created.onAction = { [weak self] action, taskID in self?.handle(action, taskID: taskID) }
        storedCenter = created
        return created
    }

    var hasCenter: Bool { storedCenter != nil }

    // MARK: Settings flow

    /// The Settings switch. On: macOS is never asked straight away; the first time it goes through
    /// the explanation (`prePermission`), and only Continue reaches the system prompt.
    func setEnabled(_ on: Bool) async {
        guard on else {
            persist(false)
            stage = .idle
            await clearScheduled()
            return
        }
        switch await center.authorization() {
        case .authorized: await enable()
        case .denied: stage = .refused
        case .notDetermined: stage = .prePermission
        }
    }

    func continueFromPrePermission() async {
        guard stage == .prePermission else { return }
        if await center.requestAuthorization() { await enable() } else { stage = .refused }
    }

    func cancelPrePermission() {
        if stage == .prePermission { stage = .idle }
    }

    /// Settings calls this when it appears, so a switch that macOS has since turned off reads as off.
    func syncWithSystem() async {
        guard isEnabled else { return }
        await refresh()
    }

    private func enable() async {
        persist(true)
        stage = .idle
        await refresh()
    }

    private func persist(_ on: Bool) {
        isEnabled = on
        defaults.set(on, forKey: Self.enabledKey)
    }

    // MARK: Scheduling

    /// Hands the controller the live model without starting the timer (a test drives refresh by hand).
    func attach(model: AppModel) {
        self.model = model
    }

    /// Wires the live model and keeps the plan current: once now, on focus changes, every minute.
    func start(model: AppModel) {
        attach(model: model)
        guard loop == nil else { return }
        if isEnabled { _ = center }
        focusObserver = NotificationCenter.default.addObserver(forName: .kronosOrdoFocusDidChange, object: nil,
                                                               queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
        focusObserver = nil
    }

    /// Brings the center in line with what the plan says. Touches nothing when off and idle, and
    /// nothing when the plan is unchanged.
    func refresh() async {
        guard isEnabled else {
            if storedCenter != nil, !lastScheduled.isEmpty { await clearScheduled() }
            return
        }
        guard let model else { return }
        let auth = await center.authorization()
        guard auth == .authorized else {
            // Switched off in System Settings (or reset): say so instead of pretending.
            persist(false)
            stage = auth == .denied ? .refused : .idle
            await clearScheduled()
            return
        }
        let desired = BlockStartPlanner.plan(candidates(model: model), now: clock.now) { line in
            String(format: String(localized: "notify.blockstart.title"), line)
        }
        let ours = await center.pendingIDs().filter { $0.hasPrefix(BlockStartPlanner.idPrefix) }
        if desired == lastScheduled, Set(ours) == Set(desired.map(\.id)) { return }
        await center.removePending(ids: ours)
        for request in desired { await center.schedule(request) }
        lastScheduled = desired
    }

    private func candidates(model: AppModel) -> [BlockStartCandidate] {
        let blocks = TimeBlocksModel(model: model, clock: clock)
        if let blockSource { blocks.setPreview(blocks: blockSource(), now: clock.now) }
        let today = Day.today(calendar: KronosLocale.calendar)
        return blocks.blocks.map { entry in
            let linked = blocks.linkedTasks(for: entry)
            let aside = ImpulsDayMemory.setAsideToday(among: linked.map(\.id), today: today)
            let task = linked.first { !aside.contains($0.id) }
                .map { BlockStartTask(id: $0.id, title: $0.title, firstMove: $0.firstMove) }
            return BlockStartCandidate(eventID: entry.event.id, blockTitle: entry.event.title,
                                       start: entry.event.start, task: task)
        }
    }

    private func clearScheduled() async {
        guard storedCenter != nil else { lastScheduled = []; return }
        let ours = await center.pendingIDs().filter { $0.hasPrefix(BlockStartPlanner.idPrefix) }
        await center.removePending(ids: ours)
        lastScheduled = []
    }

    // MARK: Notification actions

    /// What a tap on Done, Not now or Open does. A task that is gone or already finished is left
    /// alone, so a stale notification never writes anything.
    func handle(_ action: BlockStartAction, taskID: UUID) {
        guard let model, let task = model.store.task(taskID), task.deletedAt == nil else { return }
        switch action {
        case .done:
            guard KStatus.open.contains(task.status) else { return }
            model.store.complete(taskID)
            model.didMutate()
        case .notNow:
            ImpulsDayMemory.setAside(taskID, today: Day.today(calendar: KronosLocale.calendar))
            if model.pinnedFocusTaskID == taskID { model.pinnedFocusTaskID = nil }
            model.didMutate()
        case .open:
            NSApp.activate(ignoringOtherApps: true)
            model.openTaskByID(taskID)
        }
        if action != .open { Task { await refresh() } }
    }
}
