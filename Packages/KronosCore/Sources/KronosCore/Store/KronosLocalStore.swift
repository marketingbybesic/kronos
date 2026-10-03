// The device-local store: agent identities and the activity log.
//
// These rows never sync (an agent token hash and a per-device event outbox mean nothing on
// another device), so they live in their own file, `<store dir>/Kronos-local.store`, opened by
// their own ModelContainer with CloudKit off. They are never part of the main schema and hold no
// relationship to a main model: a task or agent is referenced by its UUID only.

import Foundation
import SwiftData

public enum KronosLocalStore {

    public static let fileName = "Kronos-local.store"

    /// `<directory>/Kronos-local.store`.
    public static func storeURL(in directory: URL = KronosStore.containerDirectory()) -> URL {
        directory.appendingPathComponent(fileName)
    }

    /// Opens (creating when needed) the local store in `directory`. `inMemory` is for tests.
    public static func makeContainer(directory: URL = KronosStore.containerDirectory(),
                                     inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(versionedSchema: KronosLocalSchemaV1.self)
        let config: ModelConfiguration
        if inMemory {
            config = ModelConfiguration("KronosLocal", schema: schema, isStoredInMemoryOnly: true,
                                        cloudKitDatabase: .none)
        } else {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            config = ModelConfiguration("KronosLocal", schema: schema, url: storeURL(in: directory),
                                        cloudKitDatabase: .none)
        }
        return try ModelContainer(for: schema, migrationPlan: KronosLocalMigrationPlan.self,
                                  configurations: [config])
    }
}

/// An agent allowed to work through MCP (Claude Code, Codex, Relay, ...). The token itself is
/// kept only in the secrets folder; this row holds its SHA-256.
@Model
public final class KAgent {
    public var id: UUID = UUID()
    public var slug: String = ""
    public var displayName: String = ""
    /// One monochrome letter or SF Symbol name.
    public var glyph: String = ""
    /// SHA-256 of the agent token.
    public var tokenHash: String = ""
    /// Comma-joined scopes: read, propose, write.own, write.trusted, comment, ordo.propose,
    /// rules.propose.
    public var scopesRaw: String = ""
    /// The agent's own list, created on its first delegated task.
    public var listProjectID: UUID? = nil
    /// Set only from the Kronos UI, never through MCP.
    public var webhookURL: String? = nil
    /// Name of the webhook secret in the secret store.
    public var webhookSecretName: String? = nil
    public var rateLimitPerMinute: Int = 60
    public var dailyCreateCap: Int = 40
    public var maxPendingProposals: Int = 15
    public var isEnabled: Bool = true
    public var createdAt: Date = Date()
    public var lastSeenAt: Date? = nil

    public init(slug: String, displayName: String, glyph: String = "", tokenHash: String = "",
                scopesRaw: String = "") {
        self.slug = slug
        self.displayName = displayName
        self.glyph = glyph
        self.tokenHash = tokenHash
        self.scopesRaw = scopesRaw
    }
}

/// One append-only event: the audit log of what people and agents did, and the outbox of what
/// an agent's webhook still has to hear.
@Model
public final class KActivity {
    public var id: UUID = UUID()
    /// Monotonic per store.
    public var seq: Int = 0
    public var at: Date = Date()
    /// "me", "agent:<slug>" or "system".
    public var actor: String = ""
    public var verb: String = ""
    public var taskID: UUID? = nil
    /// The agent this event concerns (the person of the task).
    public var agentID: UUID? = nil
    /// Diff, result, comment or reason as JSON.
    public var payloadJSON: String = ""
    /// 0 not applicable, 1 pending, 2 delivered, 3 dead.
    public var webhookStateRaw: Int = 0
    public var webhookAttempts: Int = 0

    public init(seq: Int, actor: String, verb: String, taskID: UUID? = nil, agentID: UUID? = nil,
                payloadJSON: String = "", at: Date = Date()) {
        self.seq = seq
        self.actor = actor
        self.verb = verb
        self.taskID = taskID
        self.agentID = agentID
        self.payloadJSON = payloadJSON
        self.at = at
    }
}
