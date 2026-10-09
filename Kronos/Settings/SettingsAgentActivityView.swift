// Kronos/Settings/SettingsAgentActivityView.swift
// One agent's activity, read-only: what it did itself, plus what the person (or another agent
// sharing one of its tasks) did to it — approved/rejected/commented/reviewed/... — newest
// first, with a last-7-days rollup. Reuses the same device-local KActivity rows every other
// agent-facing surface already reads (events_poll, the webhook digest) via
// AgentHub.activity(forAgentSlug:) — no new data model, nothing mutated here.
//
// Deliberately NOT wired into Settings > Agents from this file: SettingsAgentsTab.swift owns
// that row/button (finish-round-1 ownership split). This file is the destination view only —
// `SettingsAgentActivityView(slug:displayName:live:store:)`, same `live`/`store`/`fixture`
// triple `AgentsSettingsController` already takes (see SettingsScreen.agentsController()), so
// the caller never needs to reach into AppDelegate itself.
//
// Localization: new keys live under the `agents.*` surface (the only closed-set namespace that
// fits — see the internal notes §2.1); `agents.activity.*` / `agents.activity.verb.*`.
// NOT added to the internal notes / Localizable.xcstrings by this file: concurrent
// finish-round-1 builders were racing non-atomic writes to those two shared generated files
// (add-strings.mjs/build-strings.mjs do read-modify-write with no locking) at the time this was
// built, so a second attempt here would only re-race. The orchestrator has the exact
// [key, en, hr] rows needed (see the agent's final report) to add in one pass during
// integration; until then `String(localized:)` falls back to printing the bare key for the 23
// rows below — a cosmetic gap, not a data or behaviour gap.

import SwiftUI
import KronosCore

/// Everything concerning one agent, newest first, pushed (sheet or nav) from a row in
/// Settings > Agents.
public struct SettingsAgentActivityView: View {
    @State private var controller: AgentActivityController?
    private let make: () -> AgentActivityController

    /// `fixture` is for snapshots: nothing is read from or written to any store.
    public init(slug: String, displayName: String, live: MCPLiveController?, store: (any TaskStoring)?, fixture: Bool = false) {
        self.make = { AgentActivityController(slug: slug, displayName: displayName, live: live, store: store, fixture: fixture) }
    }

    // Same placeholder trick as SettingsAgentsTab: a modifier on an EmptyView never fires.
    public var body: some View {
        Group {
            if let controller {
                SettingsAgentActivityList(controller: controller)
            } else {
                Color.clear.frame(height: 1)
            }
        }
        .task { if controller == nil { controller = make() } }
    }
}

/// The pane itself, once its controller exists: header, last-7-days rollup, then the plain
/// reverse-chronological feed.
private struct SettingsAgentActivityList: View {
    @State private var controller: AgentActivityController
    @Environment(\.dismiss) private var dismiss

    init(controller: AgentActivityController) {
        self._controller = State(initialValue: controller)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.x5) {
                header
                if controller.unavailable {
                    Text(String(localized: "agents.activity.unavailable"))
                        .font(Typo.meta)
                        .foregroundStyle(Tok.textTertiary)
                } else {
                    weekSection
                    feedSection
                }
            }
            .padding(Space.x6)
        }
        .frame(minWidth: 420, idealWidth: 480, maxWidth: 560, minHeight: 320, idealHeight: 480)
        .background(Tok.bg)
        .onAppear { controller.refresh() }
    }

    private var header: some View {
        HStack {
            Text(String(format: String(localized: "agents.activity.title"), controller.displayName))
                .font(Typo.heading)
                .foregroundStyle(Tok.textPrimary)
            Spacer()
            Button(String(localized: "common.done")) { dismiss() }
                .kButton(.secondary, size: .compact)
                .uiTestAnchor("settings.agentactivity.done")
        }
    }

    private var weekSection: some View {
        SettingsSection(title: String(localized: "agents.activity.week.title")) {
            if controller.weekCounts.isEmpty {
                Text(String(localized: "agents.activity.week.empty"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                    .padding(.vertical, Space.x1)
            } else {
                ForEach(Array(controller.weekCounts.enumerated()), id: \.element.id) { index, count in
                    if index > 0 { KHairline().padding(.vertical, Space.x1) }
                    HStack {
                        Text(count.label)
                            .font(Typo.row)
                            .foregroundStyle(Tok.textSecondary)
                        Spacer()
                        Text("\(count.count)")
                            .font(Typo.rowTabular)
                            .foregroundStyle(Tok.textPrimary)
                    }
                    .uiTestAnchor("settings.agentactivity.week.\(count.verb)")
                }
            }
        }
    }

    private var feedSection: some View {
        SettingsSection(title: String(localized: "agents.activity.feed.title")) {
            if controller.rows.isEmpty {
                SettingsEmptyRow(text: String(localized: "agents.activity.empty"), anchor: "settings.agentactivity.empty")
            } else {
                ForEach(Array(controller.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { KHairline().padding(.vertical, Space.x1) }
                    feedRow(row)
                }
            }
        }
    }

    private func feedRow(_ row: AgentActivityController.Row) -> some View {
        VStack(alignment: .leading, spacing: Space.x1) {
            Text(row.verbLabel + " — " + row.title)
                .font(Typo.row)
                .foregroundStyle(Tok.textPrimary)
                .lineLimit(2)
            Text(row.byline.map { "\($0) · \(row.relativeTime)" } ?? row.relativeTime)
                .font(Typo.meta)
                .foregroundStyle(Tok.textTertiary)
        }
        .padding(.vertical, Space.x1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .uiTestAnchor("settings.agentactivity.row.\(row.id)")
    }
}

// MARK: - Controller

/// What the view shows: resolved rows (verb label, task title/reference, relative time, who —
/// when it was not this agent itself) and last-7-days rollup counts, derived from whichever
/// verbs the data actually contains (never a hardcoded narrower subset).
@MainActor
@Observable
final class AgentActivityController {

    struct Row: Identifiable {
        /// The underlying KActivity's `seq` — monotonic per store, unique.
        let id: Int
        let verbLabel: String
        let title: String
        let relativeTime: String
        /// "you" or another agent's slug when the row was not this agent's own action; nil for
        /// the agent's own rows (no attribution needed on its own feed).
        let byline: String?
    }

    struct Count: Identifiable {
        var id: String { verb }
        let verb: String
        let label: String
        let count: Int
    }

    let displayName: String
    private(set) var rows: [Row] = []
    private(set) var weekCounts: [Count] = []
    private(set) var unavailable = false

    private let slug: String
    private let store: (any TaskStoring)?
    private let fixture: Bool
    private var hub: AgentHub?

    init(slug: String, displayName: String, live: MCPLiveController?, store: (any TaskStoring)?, fixture: Bool = false) {
        self.slug = slug
        self.displayName = displayName
        self.store = store
        self.fixture = fixture
        if fixture { (rows, weekCounts) = Self.fixtureData(); return }
        if let h = live?.hub { hub = h }
        else if let h = try? AgentHub(directory: KronosStore.containerDirectory()) { hub = h }
        else { unavailable = true }
        refresh()
    }

    func refresh() {
        guard !fixture, let hub else { return }
        let now = Self.clockNow()
        let activity = hub.activity(forAgentSlug: slug)
        rows = activity.map { Self.row(for: $0, slug: slug, store: store, now: now) }
        let weekStart = now.addingTimeInterval(-7 * 86_400)
        weekCounts = Self.weekCounts(activity.filter { $0.at >= weekStart })
    }

    // MARK: row building

    private static func row(for activity: KActivity, slug: String, store: (any TaskStoring)?, now: Date) -> Row {
        let task = activity.taskID.flatMap { store?.taskIncludingDeleted($0) }
        // `structure.changed` carries no taskID; MCPDispatcher+Scopes.swift stashes the
        // project/area/label's name in the payload instead of a title.
        let structureName = activity.verb == ActivityVerb.structure ? AgentHub.payload(activity)["name"]?.string : nil
        let event = DigestEvent(row: activity, title: task?.title ?? structureName)
        let f = RelativeDateTimeFormatter()
        f.locale = KronosLocale.current
        f.calendar = KronosLocale.calendar
        f.unitsStyle = .full
        return Row(id: activity.seq, verbLabel: verbLabel(activity.verb), title: event.title,
                   relativeTime: f.localizedString(for: activity.at, relativeTo: now),
                   byline: byline(activity.actor, selfSlug: slug))
    }

    private static func byline(_ actor: String, selfSlug: String) -> String? {
        if actor == "agent:\(selfSlug)" { return nil }
        if actor == "me" { return String(localized: "agents.activity.actor.owner") }
        if actor.hasPrefix("agent:") { return String(actor.dropFirst("agent:".count)) }
        return nil
    }

    // MARK: rollup

    /// Declaration order of every verb that can name an agent (`cursor.ack` is bookkeeping,
    /// already excluded by `AgentHub.activity(forAgentSlug:)`).
    private static let allVerbs: [String] = [
        ActivityVerb.created, ActivityVerb.updated, ActivityVerb.doneByAgent, ActivityVerb.restored,
        ActivityVerb.reverted, ActivityVerb.structure, ActivityVerb.completed, ActivityVerb.approved,
        ActivityVerb.rejected, ActivityVerb.reopened, ActivityVerb.deleted, ActivityVerb.assigned,
        ActivityVerb.commented, ActivityVerb.edited, ActivityVerb.reviewed, ActivityVerb.unreviewed,
    ]

    private static func weekCounts(_ rows: [KActivity]) -> [Count] {
        var byVerb: [String: Int] = [:]
        for r in rows { byVerb[r.verb, default: 0] += 1 }
        return allVerbs.compactMap { verb in
            guard let n = byVerb[verb], n > 0 else { return nil }
            return Count(verb: verb, label: verbLabel(verb), count: n)
        }
    }

    static func verbLabel(_ verb: String) -> String {
        switch verb {
        case ActivityVerb.created: return String(localized: "agents.activity.verb.created")
        case ActivityVerb.updated: return String(localized: "agents.activity.verb.updated")
        case ActivityVerb.doneByAgent: return String(localized: "agents.activity.verb.donebyagent")
        case ActivityVerb.restored: return String(localized: "agents.activity.verb.restored")
        case ActivityVerb.reverted: return String(localized: "agents.activity.verb.reverted")
        case ActivityVerb.structure: return String(localized: "agents.activity.verb.structure")
        case ActivityVerb.completed: return String(localized: "agents.activity.verb.completed")
        case ActivityVerb.approved: return String(localized: "agents.activity.verb.approved")
        case ActivityVerb.rejected: return String(localized: "agents.activity.verb.rejected")
        case ActivityVerb.reopened: return String(localized: "agents.activity.verb.reopened")
        case ActivityVerb.deleted: return String(localized: "agents.activity.verb.deleted")
        case ActivityVerb.assigned: return String(localized: "agents.activity.verb.assigned")
        case ActivityVerb.commented: return String(localized: "agents.activity.verb.commented")
        case ActivityVerb.edited: return String(localized: "agents.activity.verb.edited")
        case ActivityVerb.reviewed: return String(localized: "agents.activity.verb.reviewed")
        case ActivityVerb.unreviewed: return String(localized: "agents.activity.verb.unreviewed")
        default: return verb
        }
    }

    // Snapshots render a fixed clock so the picture never depends on the day it was taken
    // (same rule as SettingsAgentsTab.lastSeenText).
    private static func clockNow() -> Date {
        ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT"] != nil
            ? Date(timeIntervalSince1970: 1_790_000_000) : Date()
    }
}
