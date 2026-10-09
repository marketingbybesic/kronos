// Kronos/MCP/AgentWorkingIndex.swift
// Which open tasks an agent is actively working on right now, derived from its own
// `update_task status: "inProgress"` writes in the last 24h (AgentTeamSignals.workClaims).
// Display-only: nothing here writes to the store, and a claim just stops mattering once the
// status leaves in-progress or 24h pass — the row glyph and Inspector line
// (ListRowView+AgentStatus.swift, InspectorReviewSection.swift) read `claim(for:)` fresh on
// every render rather than caching anything themselves.

import Foundation
import Observation
import KronosCore

@MainActor
@Observable
final class AgentWorkingIndex {
    static let shared = AgentWorkingIndex()

    private(set) var claims: [UUID: AgentClaim] = [:]
    private var names: [String: String] = [:]

    @ObservationIgnored private var hub: AgentHub?
    @ObservationIgnored private var observer: NSObjectProtocol?

    func start(hub: AgentHub) {
        self.hub = hub
        refresh()
        observer = NotificationCenter.default.addObserver(forName: .kronosStoreDidChangeExternally, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        hub = nil
        claims = [:]
    }

    private func refresh() {
        guard let hub else { return }
        let window = hub.rows(from: Date().addingTimeInterval(-86_400)).filter { $0.verb == ActivityVerb.updated }
        claims = AgentTeamSignals.workClaims(window)
        names = Dictionary(uniqueKeysWithValues: hub.agents().map { ($0.slug, $0.displayName) })
    }

    func claim(for task: KTask, now: Date = Date()) -> (name: String, at: Date)? {
        guard task.status == .inProgress, task.reviewRaw != ReviewState.awaitingCheck,
              let c = claims[task.id], now.timeIntervalSince(c.at) < 86_400 else { return nil }
        return (names[c.slug] ?? c.slug, c.at)
    }
}
