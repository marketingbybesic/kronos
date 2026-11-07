// Kronos v1.2 "run contract" (Phase 1 slice A). A **run** is an agent working on a task; while a
// run is active, its task is claimed. Runs are per-Mac process facts — they must never sync — so
// they live in their own file, `<store dir>/Kronos-runs.store`, next to `Kronos-local.store`,
// opened by their own ModelContainer with CloudKit off. Same pattern as
// `Store/KronosLocalStore.swift`: adding these models to the main schema (`KronosSchemaV2`) or
// the local schema (`KronosLocalSchemaV1`, both Runtime.swift) would force a migration of the
// person's existing stores; a new file needs none.

import Foundation
import SwiftData

/// The device-local, never-synced schema for runs and pinned harnesses.
public enum KronosRunsSchemaV1: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    public static var models: [any PersistentModel.Type] { [KAgentRun.self, KHarness.self] }
}

public enum KronosRunsMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [KronosRunsSchemaV1.self] }
    public static var stages: [MigrationStage] { [] }
}

public enum KronosRunsStore {

    public static let fileName = "Kronos-runs.store"

    /// `<directory>/Kronos-runs.store`.
    public static func storeURL(in directory: URL = KronosStore.containerDirectory()) -> URL {
        directory.appendingPathComponent(fileName)
    }

    /// Opens (creating when needed) the runs store in `directory`. `inMemory` is for tests.
    public static func makeContainer(directory: URL = KronosStore.containerDirectory(),
                                     inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(versionedSchema: KronosRunsSchemaV1.self)
        let config: ModelConfiguration
        if inMemory {
            config = ModelConfiguration("KronosRuns", schema: schema, isStoredInMemoryOnly: true,
                                        cloudKitDatabase: .none)
        } else {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            config = ModelConfiguration("KronosRuns", schema: schema, url: storeURL(in: directory),
                                        cloudKitDatabase: .none)
        }
        return try ModelContainer(for: schema, migrationPlan: KronosRunsMigrationPlan.self,
                                  configurations: [config])
    }
}

/// One agent working one task. The claim *is* the active run (no separate lease object, per the
/// Fable review that shaped this plan): while `stateRaw == "running"` and `leaseUntil` has not
/// passed, the task is claimed. `run_update` renews `leaseUntil`; a Kronos-launched run's
/// supervisor renews it as long as `pid` stays alive, so a live process is its own heartbeat.
@Model
public final class KAgentRun {
    public var id: UUID = UUID()
    public var taskID: UUID = UUID()
    public var agentID: UUID = UUID()          // KAgent.id
    public var agentSlug: String = ""
    public var stateRaw: String = "running"    // running|done|failed|stopped|expired|handoff
    public var startedAt: Date = Date()
    public var leaseUntil: Date = Date()
    public var endedAt: Date? = nil
    public var progress: Double = -1           // -1 unknown, else 0...1
    public var note: String = ""               // latest one-line status, ≤280 chars
    public var summary: String = ""            // set by finish
    public var artifactsJSON: String = ""      // [{"kind":"file|diff|commit|pr|url","ref":"…","title":"…"}]
    public var launchedByKronos: Bool = false  // true when Kronos spawned the harness
    public var pid: Int32 = 0
    public var logPath: String = ""            // ~/Library/Application Support/Kronos/Runs/<id>.log
    public var handoffToSlug: String = ""
    /// Set ONLY by `RunSupervisorEngine.tick`'s exit-0-while-running fallback (Kronos v1.2
    /// "agent loop"): the harness process exited clean without ever calling `run_finish`, so
    /// the engine closes the run as "done" on its own ("Exited without reporting") rather than
    /// losing the task. Review-next reads this to say so instead of "says it is done". Never
    /// set by `run_finish` itself (MCPDispatcher+Runs.swift never passes it).
    public var exitedWithoutReporting: Bool = false

    public init() {}
}

/// A pinned, per-agent harness executable (Settings > Agents > Harness, slice B). Defined here so
/// the runs store needs no second schema version when B ships the UI that writes it.
@Model
public final class KHarness {
    public var id: UUID = UUID()
    public var agentID: UUID = UUID()          // one harness per agent
    public var executablePath: String = ""     // absolute, pinned
    public var argvTemplate: String = ""       // JSON array of strings; placeholder "{prompt}"
    public var workingDirectory: String = ""   // absolute; empty = $HOME
    public var maxMinutes: Int = 120
    public var pinnedAt: Date = Date()

    public init() {}
}
