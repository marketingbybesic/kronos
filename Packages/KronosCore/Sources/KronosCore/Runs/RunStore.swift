// Kronos v1.2 "run contract" (Phase 1 slice A2). The store over `Kronos-runs.store`: start,
// renew, update, finish, stop and sweep a run, and read them back. Downstream slices (B harness
// supervisor, C status UI, E Flow) code against the entry points below — their signatures are a
// contract, not renamed or reshaped here.
//
// `agent: AgentIdentity?` follows MCPDispatcher's own convention: nil is the person's own process
// (Kronos itself, or a hermetic caller with no agent token) and is never refused by an ownership
// check; a run it starts is attributed to a fixed person identity so "the same caller renews"
// still holds across repeated nil calls.

import Foundation
import SwiftData
#if canImport(Darwin)
import Darwin
#endif

/// One artifact a run points at: a file, a diff, a commit, a PR or a plain URL.
public struct RunArtifact: Codable, Equatable, Sendable {
    public static let validKinds: Set<String> = ["file", "diff", "commit", "pr", "url"]

    public var kind: String
    public var ref: String
    public var title: String?

    public init(kind: String, ref: String, title: String? = nil) {
        self.kind = kind
        self.ref = ref
        self.title = title
    }

    static func decodeList(_ raw: String) -> [RunArtifact] {
        guard !raw.isEmpty, let data = raw.data(using: .utf8) else { return [] }
        return (try? AgentCoding.decoder.decode([RunArtifact].self, from: data)) ?? []
    }

    static func encodeList(_ list: [RunArtifact]) -> String {
        guard let data = try? AgentCoding.encoder.encode(list) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// How a run ended, passed to `RunStore.finish`.
public enum RunOutcome: String, Codable, Sendable {
    case done, failed, handoff
}

public enum RunError: Error, Equatable, Sendable {
    /// Another agent holds an active run on this task; carries its slug.
    case claimed(by: String)
    /// The task is a pending agent proposal: not approved, so not workable yet.
    case taskPending
    /// No live task with that id (including soft-deleted).
    case taskMissing
    /// The task is already done or canceled.
    case taskDone
    /// The caller is not the agent that holds this run.
    case notYours
    /// The run is not in state `running` (already ended, or never existed).
    case notActive
    /// `handoffTo` names no registered agent.
    case unknownAgent
    /// An artifact's `kind` is not one of file|diff|commit|pr|url. Carries the bad kind.
    case badArtifact(String)
}

@MainActor
public final class RunStore {
    private let context: ModelContext
    private let store: any TaskStoring
    private let hub: AgentHub?

    /// A fixed, non-agent identity used when `agent` is nil (the person's own process): the run
    /// still needs a concrete `agentID`/`agentSlug` to store, and repeated nil calls must resolve
    /// to the SAME identity so "the same caller renews" keeps working.
    private static let ownerAgentID = UUID(uuidString: "00000000-0000-0000-0000-00000000DA10")!
    private static let ownerSlug = "me"

    public init(context: ModelContext, store: any TaskStoring, hub: AgentHub?) {
        self.context = context
        self.store = store
        self.hub = hub
    }

    /// A store over the runs store in `directory` (the real one in the app) — same convenience
    /// pattern as `AgentHub.init(directory:)`.
    public convenience init(directory: URL, store: any TaskStoring, hub: AgentHub?) throws {
        let container = try KronosRunsStore.makeContainer(directory: directory)
        self.init(context: ModelContext(container), store: store, hub: hub)
        retainedContainer = container
    }

    /// Keeps the container alive for a store built from a directory.
    private var retainedContainer: ModelContainer?

    private func save() { try? context.save() }

    // MARK: - Reads

    /// The run with state running and `leaseUntil > now`, or nil.
    public func activeRun(taskID: UUID, now: Date = Date()) -> KAgentRun? {
        var d = FetchDescriptor<KAgentRun>(predicate: #Predicate<KAgentRun> { r in
            r.taskID == taskID && r.stateRaw == "running" && r.leaseUntil > now
        })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first
    }

    /// Every run of a task, newest first.
    public func runs(taskID: UUID) -> [KAgentRun] {
        let d = FetchDescriptor<KAgentRun>(predicate: #Predicate<KAgentRun> { $0.taskID == taskID })
        let all = (try? context.fetch(d)) ?? []
        return all.sorted { $0.startedAt > $1.startedAt }
    }

    /// Every run currently in state running (no lease check — a plain snapshot for UI; `sweep`
    /// is what actually retires a stale one to `expired`).
    public func activeRuns() -> [KAgentRun] {
        fetchRunning()
    }

    /// One run by its own id, or nil. Not a claim query — used by callers (the MCP layer) that
    /// already hold a `runID` and need to read it back.
    public func run(id: UUID) -> KAgentRun? {
        var d = FetchDescriptor<KAgentRun>(predicate: #Predicate<KAgentRun> { $0.id == id })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first
    }

    // MARK: - start

    @discardableResult
    public func start(taskID: UUID, agent: AgentIdentity?, launchedByKronos: Bool,
                      lease: TimeInterval = 1800, now: Date = Date()) throws -> KAgentRun {
        guard let task = store.task(taskID) else { throw RunError.taskMissing }
        if KStatus.closed.contains(task.status) { throw RunError.taskDone }
        if task.reviewRaw == ReviewState.pending { throw RunError.taskPending }

        if let existing = activeRun(taskID: taskID, now: now) {
            guard owns(existing, agent) else { throw RunError.claimed(by: existing.agentSlug) }
            existing.leaseUntil = now.addingTimeInterval(lease)
            save()
            logAppend(ActivityVerb.runStarted, run: existing, agent: agent, now: now)
            return existing
        }

        let run = KAgentRun()
        run.taskID = taskID
        run.agentID = agent?.agentID ?? Self.ownerAgentID
        run.agentSlug = agent?.slug ?? Self.ownerSlug
        run.stateRaw = "running"
        run.startedAt = now
        run.leaseUntil = now.addingTimeInterval(lease)
        run.launchedByKronos = launchedByKronos
        context.insert(run)
        save()
        logAppend(ActivityVerb.runStarted, run: run, agent: agent, now: now)
        return run
    }

    // MARK: - update

    public func update(runID: UUID, agent: AgentIdentity?, progress: Double?, note: String?,
                       artifactsAdd: [RunArtifact], now: Date = Date()) throws {
        guard let run = run(id: runID), run.stateRaw == "running" else { throw RunError.notActive }
        guard owns(run, agent) else { throw RunError.notYours }
        for a in artifactsAdd where !RunArtifact.validKinds.contains(a.kind) { throw RunError.badArtifact(a.kind) }

        var changed = false
        if let progress { run.progress = min(1, max(0, progress)) }
        if let note {
            let trimmed = String(note.prefix(280))
            if trimmed != run.note { run.note = trimmed; changed = true }
        }
        var artifacts = RunArtifact.decodeList(run.artifactsJSON)
        for a in artifactsAdd where !artifacts.contains(where: { $0.kind == a.kind && $0.ref == a.ref }) {
            artifacts.append(a)
            changed = true
        }
        run.artifactsJSON = RunArtifact.encodeList(artifacts)
        run.leaseUntil = now.addingTimeInterval(1800)
        save()
        if changed { logAppend(ActivityVerb.runUpdated, run: run, agent: agent, now: now) }
    }

    // MARK: - finish

    /// `exitedWithoutReporting`: default false for every real caller (the MCP `run_finish`
    /// dispatcher never passes it); true ONLY from `RunSupervisorEngine.tick`'s exit-0 fallback,
    /// so Review-next can say the agent exited without reporting instead of "says it is done".
    public func finish(runID: UUID, agent: AgentIdentity?, outcome: RunOutcome, summary: String,
                       artifactsAdd: [RunArtifact], handoffTo: String?, now: Date = Date(),
                       exitedWithoutReporting: Bool = false) throws {
        guard let run = run(id: runID), run.stateRaw == "running" else { throw RunError.notActive }
        guard owns(run, agent) else { throw RunError.notYours }
        for a in artifactsAdd where !RunArtifact.validKinds.contains(a.kind) { throw RunError.badArtifact(a.kind) }
        var targetAgent: KAgent?
        if outcome == .handoff {
            guard let handoffTo, let found = hub?.agent(slug: handoffTo) else { throw RunError.unknownAgent }
            targetAgent = found
        }

        var artifacts = RunArtifact.decodeList(run.artifactsJSON)
        for a in artifactsAdd where !artifacts.contains(where: { $0.kind == a.kind && $0.ref == a.ref }) {
            artifacts.append(a)
        }
        run.artifactsJSON = RunArtifact.encodeList(artifacts)
        run.summary = summary
        run.endedAt = now
        run.exitedWithoutReporting = exitedWithoutReporting
        // Attribution follows the RUN's own claim, not the (possibly nil, Kronos-proxied) caller:
        // a Kronos-launched run finished by its supervisor still reports as the agent that held it.
        let runAgent = resolvedRunAgent(run)

        switch outcome {
        case .done:
            run.stateRaw = "done"
            AgentDoneReport.reportDone(run.taskID, agent: runAgent, note: summary, links: nil, store: store, hub: hub, now: now)
            logAppend(ActivityVerb.runFinished, run: run, agent: agent, now: now)
        case .failed:
            run.stateRaw = "failed"
            if store.task(run.taskID) != nil {
                store.updateNoUndo(run.taskID) { t in
                    t.status = .todo
                    let note = "Run failed: \(summary)"
                    t.notes = t.notes.isEmpty ? note : t.notes + "\n" + note
                }
            }
            logAppend(ActivityVerb.runFailed, run: run, agent: agent, now: now)
        case .handoff:
            guard let targetAgent else { throw RunError.unknownAgent }   // unreachable, validated above
            run.stateRaw = "handoff"
            run.handoffToSlug = targetAgent.slug
            store.updateNoUndo(run.taskID) { $0.agentID = targetAgent.id; $0.assigneeRaw = 1 }
            hub?.append(actor: Self.ownerSlug, verb: ActivityVerb.assigned, taskID: run.taskID, agentID: targetAgent.id,
                       payload: ["title": .string(store.task(run.taskID)?.title ?? "")], at: now)
            logAppend(ActivityVerb.runFinished, run: run, agent: agent, now: now)
        }
        save()
    }

    // MARK: - stop / sweep

    /// person-only: no identity check, because only the app's UI calls it.
    public func stop(runID: UUID, now: Date = Date()) {
        guard let run = run(id: runID), run.stateRaw == "running" else { return }
        run.stateRaw = "stopped"
        run.endedAt = now
        save()
        hub?.append(actor: Self.ownerSlug, verb: ActivityVerb.runStopped, taskID: run.taskID, agentID: run.agentID, at: now)
    }

    /// Marks running runs whose lease has passed as `expired`, except a Kronos-launched run
    /// whose pid is still alive (its supervisor is the heartbeat). Returns what it swept.
    @discardableResult
    public func sweep(now: Date = Date()) -> [KAgentRun] {
        var swept: [KAgentRun] = []
        for run in fetchRunning() where run.leaseUntil <= now {
            if run.launchedByKronos && isPidAlive(run.pid) { continue }
            run.stateRaw = "expired"
            run.endedAt = now
            swept.append(run)
            hub?.append(actor: Self.ownerSlug, verb: ActivityVerb.runExpired, taskID: run.taskID, agentID: run.agentID, at: now)
        }
        if !swept.isEmpty { save() }
        return swept
    }

    // MARK: - helpers

    private func fetchRunning() -> [KAgentRun] {
        let d = FetchDescriptor<KAgentRun>(predicate: #Predicate<KAgentRun> { $0.stateRaw == "running" })
        return (try? context.fetch(d)) ?? []
    }

    /// nil identity = the person's own process; never refused (same rule MCPDispatcher uses).
    private func owns(_ run: KAgentRun, _ agent: AgentIdentity?) -> Bool {
        guard let agent else { return true }
        return run.agentID == agent.agentID
    }

    /// The real, currently-registered identity of a run's own agent (so `reportDone` sees its
    /// true scopes, e.g. `done.trusted`) — falling back to a minimal, never-auto-approving
    /// identity when the hub cannot resolve the slug (removed agent, or no hub at all).
    private func resolvedRunAgent(_ run: KAgentRun) -> AgentIdentity {
        hub?.identity(slug: run.agentSlug) ?? AgentIdentity(agentID: run.agentID, slug: run.agentSlug,
                                                             displayName: run.agentSlug, scopes: AgentScopes([]))
    }

    private func logAppend(_ verb: String, run: KAgentRun, agent: AgentIdentity?, now: Date) {
        hub?.append(actor: agent?.actor ?? "agent:\(run.agentSlug)", verb: verb, taskID: run.taskID, agentID: run.agentID,
                   payload: ["agent": .string(run.agentSlug), "state": .string(run.stateRaw)], at: now)
    }

    private func isPidAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        #if canImport(Darwin)
        return kill(pid, 0) == 0
        #else
        return false
        #endif
    }
}
