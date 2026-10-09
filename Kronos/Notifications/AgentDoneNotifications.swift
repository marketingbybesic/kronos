// Kronos/Notifications/AgentDoneNotifications.swift
// The one agent-completion notification channel: "Finished by <agent>" (or a batched count) when
// agent-originated work closes and is worth a look, with a Review action that opens Review next.
// Off until the person flips the switch in Settings; macOS permission is asked only from that
// switch, after one line of explanation. Nothing is sent while Kronos is the active app, and an
// auto-approved completion (AgentTeamSignals.notifiable) never notifies.
//
// Hermetic runs (live test, snapshots, a store directory override) get a recording center: nothing
// is ever asked of, or sent to, the real system from a test.
import AppKit
import Observation
import KronosCore

@MainActor
@Observable
final class AgentDoneNotifications {
    static let shared = AgentDoneNotifications()
    static let enabledKey = "kronos.notify.agentdone.enabled"

    private(set) var isEnabled: Bool
    private(set) var stage: BlockStartNotifications.Stage = .idle

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let makeCenter: @MainActor () -> NotificationCentering
    @ObservationIgnored private var storedCenter: NotificationCentering?
    @ObservationIgnored private var hub: AgentHub?
    @ObservationIgnored private var cursor = 0
    @ObservationIgnored private var observer: NSObjectProtocol?

    init(defaults: UserDefaults = KronosEnv.defaults,
         makeCenter: @escaping @MainActor () -> NotificationCentering = BlockStartNotifications.defaultCenter) {
        self.defaults = defaults
        self.makeCenter = makeCenter
        self.isEnabled = defaults.bool(forKey: Self.enabledKey)
    }

    /// Created on first use, so an app with the channel off never touches the system center.
    var center: NotificationCentering {
        if let storedCenter { return storedCenter }
        let created = makeCenter()
        created.onReviewOpen = { _ in
            NSApp.activate(ignoringOtherApps: true)
            AppDelegate.shared?.model.isReviewNextOpen = true
        }
        storedCenter = created
        return created
    }

    // MARK: Settings flow

    /// The Settings switch. On: macOS is never asked straight away; the first time it goes through
    /// the explanation (`prePermission`), and only Continue reaches the system prompt.
    func setEnabled(_ on: Bool) async {
        guard on else {
            persist(false)
            stage = .idle
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
        let auth = await center.authorization()
        guard auth != .authorized else { return }
        persist(false)
        stage = auth == .denied ? .refused : .idle
    }

    private func enable() async {
        persist(true)
        stage = .idle
    }

    private func persist(_ on: Bool) {
        isEnabled = on
        defaults.set(on, forKey: Self.enabledKey)
    }

    // MARK: Agent feed

    /// Wires the live hub and starts watching for finished agent work. `store` matches the other
    /// agent feeds' start signature; this channel reads everything it needs off the activity row.
    func start(hub: AgentHub, store: any TaskStoring) {
        self.hub = hub
        cursor = hub.latestSeq
        observer = NotificationCenter.default.addObserver(forName: .kronosStoreDidChangeExternally, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        hub = nil
    }

    /// One notification per batch of fresh rows: a single finish names the agent and task, two or
    /// more collapse into a count. The cursor always advances, even while off, so turning the
    /// switch on later never replays old history; nothing is sent while Kronos is the active app.
    private func check() {
        guard let hub else { return }
        let fresh = hub.rows(since: cursor)
        cursor = fresh.last?.seq ?? cursor
        guard isEnabled, !NSApp.isActive else { return }
        let done = AgentTeamSignals.notifiable(fresh)
        guard !done.isEmpty else { return }
        Task {
            guard await center.authorization() == .authorized else { persist(false); stage = .idle; return }
            guard let last = done.last, let taskID = last.taskID else { return }
            let title: String
            let body: String
            if done.count == 1 {
                let slug = String(last.actor.dropFirst("agent:".count))
                let name = hub.agent(slug: slug)?.displayName ?? slug
                title = String(format: String(localized: "agents.notify.done.title"), name)
                body = AgentHub.payload(last)["title"]?.string ?? ""
            } else {
                title = String(format: String(localized: "agents.notify.done.many"), done.count)
                body = ""
            }
            await center.deliver(AgentDoneRequest(id: "kronos.agentdone.\(last.seq)", taskID: taskID, title: title, body: body))
        }
    }
}
