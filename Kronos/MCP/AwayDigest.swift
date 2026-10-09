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
    static let lastActiveKey = "kronos.digest.lastActiveAt"

    private(set) var summary: AgentAwaySummary?

    @ObservationIgnored private var hub: AgentHub?
    @ObservationIgnored private var sinceAnchor: Date?
    @ObservationIgnored private var activeObserver: NSObjectProtocol?
    @ObservationIgnored private var resignObserver: NSObjectProtocol?
    @ObservationIgnored private var terminateObserver: NSObjectProtocol?

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
    }

    func stop() {
        for o in [activeObserver, resignObserver, terminateObserver] { if let o { NotificationCenter.default.removeObserver(o) } }
        activeObserver = nil; resignObserver = nil; terminateObserver = nil
        hub = nil
    }

    private func evaluate() {
        guard let hub else { return }
        let stored = KronosEnv.defaults.double(forKey: Self.lastActiveKey)
        guard stored > 0 else { KronosEnv.defaults.set(Date().timeIntervalSince1970, forKey: Self.lastActiveKey); return }
        let storedDate = Date(timeIntervalSince1970: stored)
        guard Date().timeIntervalSince(storedDate) >= Self.awayThreshold else { return }
        let since = sinceAnchor ?? storedDate
        let s = AgentTeamSignals.awaySummary(hub.rows(from: since))
        if !s.isEmpty { summary = s; sinceAnchor = since }
    }

    func dismiss() { summary = nil }

    func openReview(model: AppModel) {
        model.isReviewNextOpen = true
        dismiss()
    }
}
