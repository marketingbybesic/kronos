// Kronos/MCP/AwayDigest.swift
// "While you were away" — what agents finished or proposed since the person's last active moment,
// when that gap lasted at least `awayThreshold`, surfaced as one line above the list
// (AwayDigestBanner) until dismissed or reviewed. Nothing here writes to the store; the only
// persisted value is `lastActiveAt`, in KronosEnv.defaults, so a hermetic run never touches the
// person's real away/active history.

import AppKit
import Observation
import KronosCore

@MainActor
@Observable
final class AwayDigest {
    static let shared = AwayDigest()
    static let awayThreshold: TimeInterval = 4 * 3600
    /// D3 (Kronos v1.2 Phase 2 slice D): an item pending (or awaiting the person's check) with
    /// no change in over this long — the review queue rotting unseen, independent of whether
    /// the person was ever technically "away".
    static let agingThreshold: TimeInterval = 24 * 3600
    static let lastActiveKey = "kronos.digest.lastActiveAt"

    private(set) var summary: AgentAwaySummary?
    /// Items stuck past `agingThreshold`, recomputed on every `evaluate()` tick alongside
    /// `summary` — the SAME banner (AwayDigestBanner.swift) shows this as a second line,
    /// regardless of whether `summary` itself is nil.
    private(set) var agingCount: Int = 0

    @ObservationIgnored private var hub: AgentHub?
    @ObservationIgnored private var sinceAnchor: Date?
    @ObservationIgnored private var activeObserver: NSObjectProtocol?
    @ObservationIgnored private var resignObserver: NSObjectProtocol?
    @ObservationIgnored private var terminateObserver: NSObjectProtocol?
    /// Without this, `agingCount` only refreshes on activate/resign/start — a continuous
    /// foreground session (no app switch for hours) would never notice an item crossing the
    /// 24h aging threshold, exactly the "review queue rots unseen" gap D3 exists to close.
    /// 5 min is plenty of granularity against a 24h threshold and cheap (one task-list scan).
    @ObservationIgnored private var agingTimer: Timer?

    func start(hub: AgentHub) {
        self.hub = hub
        evaluate()
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { KronosEnv.defaults.set(Date().timeIntervalSince1970, forKey: Self.lastActiveKey) }
        }
        terminateObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { KronosEnv.defaults.set(Date().timeIntervalSince1970, forKey: Self.lastActiveKey) }
        }
        agingTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.agingCount = Self.computeAgingCount() }
        }
    }

    func stop() {
        for o in [activeObserver, resignObserver, terminateObserver] { if let o { NotificationCenter.default.removeObserver(o) } }
        activeObserver = nil; resignObserver = nil; terminateObserver = nil
        agingTimer?.invalidate()
        agingTimer = nil
        hub = nil
    }

    private func evaluate() {
        guard let hub else { return }
        agingCount = Self.computeAgingCount()
        let stored = KronosEnv.defaults.double(forKey: Self.lastActiveKey)
        guard stored > 0 else { KronosEnv.defaults.set(Date().timeIntervalSince1970, forKey: Self.lastActiveKey); return }
        let storedDate = Date(timeIntervalSince1970: stored)
        guard Date().timeIntervalSince(storedDate) >= Self.awayThreshold else { return }
        let since = sinceAnchor ?? storedDate
        let s = AgentTeamSignals.awaySummary(hub.rows(from: since))
        if !s.isEmpty { summary = s; sinceAnchor = since }
    }

    /// Live store state, not the activity log: a pending item's "stuck" clock is its task
    /// row's own `updatedAt` (ReviewQueue.swift's own candidates), not an activity row's
    /// timestamp — the log records transitions, this wants the last time anything happened.
    /// The threshold comparison itself is `AgentTeamSignals.agingCount` (KronosCore, table-
    /// tested); this only gathers the live `updatedAt` dates to feed it.
    private static func computeAgingCount() -> Int {
        guard let store = AppDelegate.shared?.store else { return 0 }
        let today = Day.today(calendar: KronosLocale.calendar)
        ReviewSnooze.prune(today: today)
        let items = ReviewQueue.items(in: store.allTasks(), snoozed: ReviewSnooze.table, today: today)
        return AgentTeamSignals.agingCount(updatedAt: items.map { $0.primary.updatedAt }, threshold: agingThreshold, now: Date())
    }

    func dismiss() { summary = nil; agingCount = 0 }

    func openReview(model: AppModel) {
        model.isReviewNextOpen = true
        dismiss()
    }
}
