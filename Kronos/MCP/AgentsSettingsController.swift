// What Settings > Agents shows and does. It works on the same device-local agent store as the
// running MCP server (the live hub when the server runs, its own handle on that file when MCP is
// off) and never touches the person's task data except through "Revert today's changes".

import Foundation
import KronosCore

@MainActor
@Observable
final class AgentsSettingsController {

    struct Row: Identifiable, Equatable {
        var id: String { slug }
        let slug: String
        let name: String
        let glyph: String
        let isEnabled: Bool
        let isShared: Bool          // registered through the shared legacy token, no token of its own
        let lastSeen: Date?
        let writesWeek: Int
        let scopes: AgentScopes
        let target: String?
        let undelivered: Int
        let dead: Int
        let createdToday: Int
        let dailyCap: Int
        let pending: Int
        let pendingCap: Int
        let callsMinute: Int
        let perMinute: Int
    }

    enum DeliveryKind: String, CaseIterable { case off, webhook, ntfy, command }

    private(set) var rows: [Row] = []
    private(set) var unavailable = false
    /// A one-line outcome shown under the list (revert result, add result).
    var message: String?
    /// A signing secret shown once, per agent.
    private(set) var shownSecret: [String: String] = [:]

    private var hub: AgentHub?
    private let store: (any TaskStoring)?
    private let fixture: Bool

    /// `fixture` rows are for snapshots: nothing is read from or written to any store.
    init(live: MCPLiveController?, store: (any TaskStoring)?, fixture: Bool = false) {
        self.store = store
        self.fixture = fixture
        if fixture { rows = Self.fixtureRows(); return }
        if let h = live?.hub { hub = h }
        else if let h = try? AgentHub(directory: KronosStore.containerDirectory()) { hub = h }
        else { unavailable = true }
        refresh()
    }

    func refresh() {
        guard !fixture, let hub else { return }
        hub.adoptTokenFiles()   // token-file agents (Connect all) are listed with their own token
        rows = hub.agents().map { a in
            let d = hub.undelivered(agentID: a.id)
            let created = hub.identity(slug: a.slug).map { hub.createsToday(agent: $0) } ?? 0
            let pendingCount = store.map { hub.pendingProposals(agentID: a.id, store: $0) } ?? 0
            let calls = hub.callsThisMinute(slug: a.slug, perMinute: a.rateLimitPerMinute)
            return Row(slug: a.slug, name: a.displayName, glyph: a.glyph.isEmpty ? String(a.displayName.prefix(1)) : a.glyph,
                       isEnabled: a.isEnabled, isShared: a.tokenHash.isEmpty, lastSeen: a.lastSeenAt,
                       writesWeek: hub.writeCount(agentID: a.id, days: 7), scopes: AgentScopes(csv: a.scopesRaw),
                       target: a.webhookURL, undelivered: d.pending, dead: d.dead,
                       createdToday: created, dailyCap: a.dailyCreateCap, pending: pendingCount,
                       pendingCap: a.maxPendingProposals, callsMinute: calls, perMinute: a.rateLimitPerMinute)
        }
    }

    func setEnabled(_ enabled: Bool, slug: String) {
        guard !fixture else { return }
        hub?.setEnabled(enabled, slug: slug)
        refresh()
    }

    /// Full control (scope write.all): off by default, decided here and never over MCP. Only an agent
    /// that still has no token of its own (the shared legacy token, pinned to read + propose) is
    /// refused; the row shows the switch disabled with the fix (Connect all).
    func setFullControl(_ on: Bool, slug: String) {
        guard !fixture, let hub, let agent = hub.agent(slug: slug), !agent.tokenHash.isEmpty else { return }
        var scopes = AgentScopes(csv: agent.scopesRaw)
        if on { scopes.set.insert(.writeAll) } else { scopes.set.remove(.writeAll) }
        hub.setScopes(scopes, slug: slug)
        refresh()
    }

    func setAutoApprove(_ on: Bool, slug: String) {
        guard !fixture, let hub, let agent = hub.agent(slug: slug) else { return }
        var scopes = AgentScopes(csv: agent.scopesRaw)
        if on { scopes.set.insert(.doneTrusted) } else { scopes.set.remove(.doneTrusted) }
        hub.setScopes(scopes, slug: slug)
        refresh()
    }

    /// A new token for the agent; the old one stops working at once.
    func rotateToken(slug: String) {
        guard !fixture else { return }
        _ = hub?.rotateToken(slug: slug)
        refresh()
    }

    func remove(slug: String) {
        guard !fixture else { return }
        hub?.remove(slug: slug)
        FileSecretStore().delete(Self.secretName(slug))
        refresh()
    }

    func revertToday(slug: String) {
        guard !fixture, let hub, let store, let agent = hub.agent(slug: slug) else { return }
        let s = hub.revertToday(agentID: agent.id, store: store)
        message = String(format: String(localized: "agents.revert.result"), s.total, s.skipped)
        NotificationCenter.default.post(name: .kronosStoreDidChangeExternally, object: nil)
        refresh()
    }

    @discardableResult
    func add(name: String) -> Bool {
        guard !fixture, let hub else { return false }
        guard let made = hub.addAgent(displayName: name) else {
            message = String(localized: "agents.add.failed")
            return false
        }
        let file = hub.tokenFiles?.directory.appendingPathComponent(made.agent.slug + ".token").path ?? ""
        message = String(format: String(localized: "agents.add.done"), file, made.agent.slug)
        refresh()
        return true
    }

    // MARK: delivery

    static func secretName(_ slug: String) -> String { "agent-\(slug)-hook" }

    static func kind(of target: String?) -> DeliveryKind {
        switch DeliveryTarget.parse(target) {
        case .none: return .off
        case .webhook: return .webhook
        case .ntfy: return .ntfy
        case .command: return .command
        }
    }

    /// The field text for a stored target (the part after the kind's prefix).
    static func text(of target: String?) -> String {
        switch DeliveryTarget.parse(target) {
        case .none: return ""
        case .webhook(let u), .ntfy(let u): return u.absoluteString
        case .command(let argv): return argv.joined(separator: " ")
        }
    }

    /// The stored target for what the person typed, nil when it is not valid (or the kind is off).
    static func target(kind: DeliveryKind, text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .off: return nil
        case .webhook: return DeliveryTarget.parse(t).flatMap { if case .webhook = $0 { return $0.stored } else { return nil } }
        case .ntfy: return DeliveryTarget.parse("ntfy+" + t).map(\.stored)
        case .command:
            let argv = t.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !argv.isEmpty else { return nil }
            return DeliveryTarget.command(argv).stored
        }
    }

    /// Saves the delivery target. False when the text is not valid for the kind.
    @discardableResult
    func saveDelivery(slug: String, kind: DeliveryKind, text: String) -> Bool {
        guard !fixture, let hub else { return false }
        if kind == .off {
            hub.setDeliveryTarget(nil, slug: slug)
        } else {
            guard let stored = Self.target(kind: kind, text: text) else { return false }
            hub.setDeliveryTarget(stored, slug: slug)
        }
        hub.setWebhookSecretName(kind == .webhook ? Self.secretName(slug) : nil, slug: slug)
        refresh()
        return true
    }

    /// Makes a fresh signing secret for the webhook, stores it, and shows it once.
    func newSecret(slug: String) {
        guard !fixture, let secret = AgentTokenFiles.generateToken() else { return }
        try? FileSecretStore().write(secret, name: Self.secretName(slug))
        hub?.setWebhookSecretName(Self.secretName(slug), slug: slug)
        shownSecret[slug] = secret
    }

    func dismissSecret(slug: String) { shownSecret[slug] = nil }

    // MARK: fixtures

    // Proper names of the snapshot fixture agents.
    private static let fixtureNames = ["Claude Code", "Research agent", "Unnamed agent", "pi"]

    private static func fixtureRows() -> [Row] {
        let names = fixtureNames
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        return [
            Row(slug: "claude-code", name: names[0], glyph: "C", isEnabled: true, isShared: false,
                lastSeen: now.addingTimeInterval(-600), writesWeek: 12, scopes: .standard, target: nil, undelivered: 0, dead: 0,
                createdToday: 3, dailyCap: 40, pending: 1, pendingCap: 15, callsMinute: 2, perMinute: 60),
            Row(slug: "research", name: names[1], glyph: "R", isEnabled: true, isShared: false,
                lastSeen: now.addingTimeInterval(-86_400), writesWeek: 3,
                scopes: AgentScopes([.read, .propose, .writeOwn, .comment, .writeTrusted]),
                target: "https://agent.example.com/ingest", undelivered: 2, dead: 1,
                createdToday: 12, dailyCap: 40, pending: 4, pendingCap: 15, callsMinute: 0, perMinute: 60),
            Row(slug: "unnamed", name: names[2], glyph: "U", isEnabled: false, isShared: true,
                lastSeen: nil, writesWeek: 0, scopes: .legacy, target: nil, undelivered: 0, dead: 0,
                createdToday: 0, dailyCap: 40, pending: 0, pendingCap: 15, callsMinute: 0, perMinute: 60),
            // Made by Connect all (token file only): its own token, so it holds Full control like the rest.
            Row(slug: "pi", name: names[3], glyph: "P", isEnabled: true, isShared: false,
                lastSeen: now.addingTimeInterval(-3_600), writesWeek: 1, scopes: .standard, target: nil, undelivered: 0, dead: 0,
                createdToday: 1, dailyCap: 40, pending: 0, pendingCap: 15, callsMinute: 0, perMinute: 60),
        ]
    }
}
