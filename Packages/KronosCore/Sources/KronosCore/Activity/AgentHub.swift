// The agent registry and its authentication, over the device-local store (KAgent rows). The
// hub never opens a store itself: it is handed a ModelContext, so tests use an in-memory one and
// the person's data is never reached by accident.

import Foundation
import SwiftData

@MainActor
public final class AgentHub {
    public let context: ModelContext
    public let tokenFiles: AgentTokenFiles?
    let now: () -> Date
    let limiter: AgentLimiter

    /// `tokenFiles` nil = no token files (tests that never touch disk).
    public init(context: ModelContext, tokenFiles: AgentTokenFiles? = nil, now: @escaping () -> Date = { Date() }) {
        self.context = context
        self.tokenFiles = tokenFiles
        self.now = now
        self.limiter = AgentLimiter(now: now)
    }

    /// A hub over the device-local store in `directory` (the real one in the app).
    public convenience init(directory: URL, tokenFiles: AgentTokenFiles? = .standard(),
                            now: @escaping () -> Date = { Date() }) throws {
        let container = try KronosLocalStore.makeContainer(directory: directory)
        self.init(context: ModelContext(container), tokenFiles: tokenFiles, now: now)
        retainedContainer = container
    }

    /// Keeps the container alive for a hub built from a directory.
    private var retainedContainer: ModelContainer?

    func save() { try? context.save() }

    // MARK: - Registry

    public func agents() -> [KAgent] {
        let all = (try? context.fetch(FetchDescriptor<KAgent>())) ?? []
        return all.sorted { $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.slug < $1.slug }
    }

    public func agent(slug: String) -> KAgent? { agents().first { $0.slug == slug } }
    public func agent(id: UUID) -> KAgent? { agents().first { $0.id == id } }

    @discardableResult
    public func register(slug: String, displayName: String? = nil, scopes: AgentScopes = .standard,
                         tokenHash: String = "") -> KAgent {
        if let existing = agent(slug: slug) { return existing }
        let name = displayName ?? Self.displayName(forSlug: slug)
        let a = KAgent(slug: slug, displayName: name, glyph: String(name.prefix(1)).uppercased(),
                       tokenHash: tokenHash, scopesRaw: scopes.csv)
        a.createdAt = now()
        context.insert(a)
        save()
        return a
    }

    static func displayName(forSlug slug: String) -> String {
        slug.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    public func setEnabled(_ enabled: Bool, slug: String) {
        guard let a = agent(slug: slug) else { return }
        a.isEnabled = enabled
        save()
    }

    public func setScopes(_ scopes: AgentScopes, slug: String) {
        guard let a = agent(slug: slug) else { return }
        a.scopesRaw = scopes.csv
        save()
    }

    /// Sets how the agent hears events (see `DeliveryTarget`); nil or empty turns delivery off.
    /// Only the Kronos UI calls this: no MCP tool can reach it.
    public func setDeliveryTarget(_ raw: String?, slug: String) {
        guard let a = agent(slug: slug) else { return }
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        a.webhookURL = (trimmed?.isEmpty ?? true) ? nil : trimmed
        save()
    }

    /// Names the secret (in the secret store) that signs this agent's webhook; nil clears it.
    public func setWebhookSecretName(_ name: String?, slug: String) {
        guard let a = agent(slug: slug) else { return }
        a.webhookSecretName = name
        save()
    }

    /// Creates an agent with a fresh token file and returns the token (shown once in the UI).
    @discardableResult
    public func addAgent(displayName: String, scopes: AgentScopes = .standard) -> (agent: KAgent, token: String)? {
        guard let slug = AgentTokenFiles.slug(from: displayName), agent(slug: slug) == nil,
              let token = AgentTokenFiles.generateToken() else { return nil }
        if let tokenFiles { do { try tokenFiles.write(token, slug: slug) } catch { return nil } }
        let a = register(slug: slug, displayName: displayName.trimmingCharacters(in: .whitespaces), scopes: scopes,
                         tokenHash: AgentTokenFiles.hash(token))
        return (a, token)
    }

    /// A new token for an agent; the old one stops working at once.
    public func rotateToken(slug: String) -> String? {
        guard let a = agent(slug: slug), let token = AgentTokenFiles.generateToken() else { return nil }
        if let tokenFiles { do { try tokenFiles.write(token, slug: slug) } catch { return nil } }
        a.tokenHash = AgentTokenFiles.hash(token)
        save()
        return token
    }

    /// Removes the agent row and its token file. Its events stay in the log.
    public func remove(slug: String) {
        guard let a = agent(slug: slug) else { return }
        context.delete(a)
        tokenFiles?.delete(slug)
        save()
    }

    // MARK: - Authentication

    public enum AuthResult: Equatable, Sendable {
        case agent(AgentIdentity)
        case denied
    }

    /// Resolves a Bearer value to an agent. `legacyToken` is the shared token: a match is the
    /// unnamed legacy agent (read + propose), named after `client` when that does not collide
    /// with a real agent.
    public func authenticate(bearer: String?, legacyToken: String?, client: String?) -> AuthResult {
        guard let bearer, !bearer.isEmpty else { return .denied }
        let hash = AgentTokenFiles.hash(bearer)

        if let row = rowMatching(hash: hash) ?? rescanTokenFiles(hash: hash) {
            guard row.isEnabled else { return .denied }
            touch(row)
            return .agent(Self.identity(of: row, legacy: false))
        }
        if let legacyToken, !legacyToken.isEmpty, Self.constantTimeEquals(bearer, legacyToken) {
            var slug = client.flatMap(AgentTokenFiles.slug(from:)) ?? "unnamed"
            if let existing = agent(slug: slug), !existing.tokenHash.isEmpty { slug = "unnamed" }
            let row = agent(slug: slug) ?? register(slug: slug, displayName: slug == "unnamed" ? "Unnamed agent" : nil,
                                                    scopes: .legacy)
            guard row.isEnabled else { return .denied }
            touch(row)
            var id = Self.identity(of: row, legacy: true)
            id.scopes = .legacy
            return .agent(id)
        }
        return .denied
    }

    private func rowMatching(hash: String) -> KAgent? {
        var found: KAgent?
        for row in agents() where !row.tokenHash.isEmpty {
            // No early exit: every row is compared whatever matched.
            if Self.constantTimeEquals(row.tokenHash, hash) { found = row }
        }
        return found
    }

    /// A token file written by Connect all (or by hand) registers its agent the first time its
    /// token is presented; a rotated file refreshes the stored hash.
    private func rescanTokenFiles(hash: String) -> KAgent? {
        guard let tokenFiles else { return nil }
        for slug in tokenFiles.allSlugs() {
            guard let token = tokenFiles.read(slug), Self.constantTimeEquals(AgentTokenFiles.hash(token), hash) else { continue }
            let row = agent(slug: slug) ?? register(slug: slug, scopes: .standard)
            row.tokenHash = hash
            save()
            return row
        }
        return nil
    }

    /// Brings the registry in line with the token files on disk, so every agent that holds a token
    /// is listed and can hold scopes: a file with no row gets a row (standard rights), and a row
    /// that was registered through the shared token (no hash of its own) takes the file's hash and,
    /// if it still carried only the legacy rights, the standard ones. Returns true when anything changed.
    @discardableResult
    public func adoptTokenFiles() -> Bool {
        guard let tokenFiles else { return false }
        var changed = false
        for slug in tokenFiles.allSlugs() {
            guard let token = tokenFiles.read(slug) else { continue }
            let hash = AgentTokenFiles.hash(token)
            if let row = agent(slug: slug) {
                guard row.tokenHash != hash else { continue }
                if row.tokenHash.isEmpty, AgentScopes(csv: row.scopesRaw) == .legacy { row.scopesRaw = AgentScopes.standard.csv }
                row.tokenHash = hash
            } else {
                register(slug: slug, scopes: .standard, tokenHash: hash)
            }
            changed = true
        }
        if changed { save() }
        return changed
    }

    private func touch(_ row: KAgent) {
        let t = now()
        if let last = row.lastSeenAt, t.timeIntervalSince(last) < 30 { return }
        row.lastSeenAt = t
        save()
    }

    static func identity(of row: KAgent, legacy: Bool) -> AgentIdentity {
        AgentIdentity(agentID: row.id, slug: row.slug, displayName: row.displayName,
                      scopes: AgentScopes(csv: row.scopesRaw), isLegacy: legacy,
                      rateLimitPerMinute: row.rateLimitPerMinute, dailyCreateCap: row.dailyCreateCap,
                      maxPendingProposals: row.maxPendingProposals)
    }

    /// The identity of a registered agent without authenticating (tests, Settings).
    public func identity(slug: String) -> AgentIdentity? {
        agent(slug: slug).map { Self.identity(of: $0, legacy: false) }
    }

    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = UInt8(truncatingIfNeeded: x.count ^ y.count)
        for i in 0..<max(x.count, y.count) {
            diff |= (i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0)
        }
        return diff == 0
    }
}
