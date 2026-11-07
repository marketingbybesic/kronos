// Kronos v1.2 "harness control" (Phase 2 slice B2). The state machine — launch, lease-renew,
// enforce maxMinutes, reap an exited process into done/failed, stop/escalate, the "N agents at
// once" cap — all of it pure against an INJECTED spawner, same split as
// `WebhookDelivery.swift`'s `WebhookDispatcher` (the state machine, here) vs
// `Kronos/Delivery/WebhookDeliveryController.swift` (the transport and the timer, there).
// `Kronos/Runs/RunSupervisor.swift` is this file's transport-and-timer counterpart: the real
// `Process`, the real 15 s tick, the real log file. Everything time-based here is driven by an
// explicit `now:`, so a test advances a clock instead of sleeping (same convention `RunStore`
// and `AgentRig.advance(_:)` already use).

import Foundation

/// What `ProcessSpawning` is asked to start. No shell: `executablePath` is invoked directly,
/// `arguments` go through unexpanded, `environment` REPLACES whatever the caller would otherwise
/// inherit (B2: "nothing else inherited").
public struct ProcessSpec: Sendable {
    public let executablePath: String
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: String
    /// Where merged stdout+stderr goes; the real spawner creates it 0600 before launch.
    public let logPath: String

    public init(executablePath: String, arguments: [String], environment: [String: String],
               workingDirectory: String, logPath: String) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.logPath = logPath
    }
}

/// A live or exited child process, as the engine needs to see it. The real implementation
/// (`Kronos/Runs/RunSupervisor.swift`) wraps `Foundation.Process`; tests inject a fake whose
/// `isRunning`/`terminationStatus` the test flips directly — no real process, no real sleeping.
public protocol SpawnedProcess: AnyObject {
    var pid: Int32 { get }
    var isRunning: Bool { get }
    /// nil while running; the exit code once it is not.
    var terminationStatus: Int32? { get }
    /// SIGTERM.
    func terminate()
    /// SIGKILL.
    func kill()
}

public protocol ProcessSpawning {
    func spawn(_ spec: ProcessSpec) throws -> any SpawnedProcess
}

/// `RunSupervisorEngine.launch` failures. `RunError` cases from the underlying `RunStore.start`
/// are carried through by name so a caller sees one error type.
public enum RunLaunchError: Error, Equatable, Sendable {
    case capReached(Int)
    case harnessUnpinned
    case harnessChanged
    case claimed(by: String)
    case taskPending
    case taskMissing
    case taskDone
    case spawnFailed(String)

    init(_ e: RunError) {
        switch e {
        case .claimed(let by): self = .claimed(by: by)
        case .taskPending: self = .taskPending
        case .taskMissing: self = .taskMissing
        case .taskDone: self = .taskDone
        case .notYours, .notActive, .unknownAgent, .badArtifact: self = .spawnFailed("\(e)")
        }
    }
}

@MainActor
public final class RunSupervisorEngine {
    private struct Tracked {
        let handle: any SpawnedProcess
        let agent: AgentIdentity
        let maxMinutes: Int
        let startedAt: Date
        let logPath: String
    }

    private let runs: RunStore
    private let harness: HarnessStore
    private let spawner: any ProcessSpawning
    private let logDirectory: URL
    /// Path of THIS app instance's `mcp_endpoint.json`. Injected into every child as
    /// `KRONOS_MCP_ENDPOINT_FILE` so a harness reports back to the instance that launched it —
    /// without it, kronos-cli's hardcoded default points at the REAL app's secrets dir, and a
    /// Demo-launched harness would silently run_update against the person's live store.
    private let endpointFilePath: String?
    private var handles: [UUID: Tracked] = [:]
    private var stopRequestedAt: [UUID: Date] = [:]

    public init(runs: RunStore, harness: HarnessStore, spawner: any ProcessSpawning, logDirectory: URL,
                endpointFilePath: String? = nil) {
        self.runs = runs
        self.harness = harness
        self.spawner = spawner
        self.logDirectory = logDirectory
        self.endpointFilePath = endpointFilePath
    }

    /// Every run this engine instance is actively supervising (has a live `SpawnedProcess` for).
    /// Does not include a Kronos-launched run from a previous app lifetime — `RunStore.sweep`
    /// is what protects those from an expired lease via raw pid liveness.
    public var liveRunIDs: Set<UUID> { Set(handles.keys) }

    // MARK: - launch

    /// Claims `task` for `agent` (`RunStore.start(launchedByKronos: true)`) and spawns its pinned
    /// harness. `promptBuilder` is called with the REAL run id (only known once the claim
    /// succeeds), so the prompt can tell the agent its own run id (B3).
    /// `model` (handoff-ui slice): the chosen model for this launch, or nil/blank for "Auto" —
    /// inserted as the agent's own flag (`HarnessDefaults.modelFlag(forSlug:)`) right before the
    /// prompt argument. nil leaves the composed argv exactly as it was before this parameter
    /// existed (`HarnessArgv.substituting`'s own doc comment).
    @discardableResult
    public func launch(task: KTask, agent: AgentIdentity, cap: Int, now: Date = Date(), model: String? = nil,
                       promptBuilder: (_ runID: UUID) -> String) throws -> KAgentRun {
        let activeCount = runs.activeRuns().filter(\.launchedByKronos).count
        guard activeCount < cap else { throw RunLaunchError.capReached(cap) }

        guard let h = harness.harness(agentID: agent.agentID), !h.executablePath.isEmpty else {
            throw RunLaunchError.harnessUnpinned
        }
        guard harness.validate(agentID: agent.agentID) != .changed else { throw RunLaunchError.harnessChanged }

        let run: KAgentRun
        do {
            run = try runs.start(taskID: task.id, agent: agent, launchedByKronos: true, now: now)
        } catch let e as RunError {
            throw RunLaunchError(e)
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let argv = HarnessArgv.substituting(HarnessArgv.decode(h.argvTemplate), prompt: promptBuilder(run.id),
                                            model: model, slug: agent.slug)
        let workingDirectory = h.workingDirectory.isEmpty ? home : h.workingDirectory
        let logPath = logDirectory.appendingPathComponent("\(run.id.uuidString).log").path
        var environment = ["HOME": home,
                           "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\(home)/.local/bin",
                           "KRONOS_RUN_ID": run.id.uuidString,
                           "KRONOS_TASK_ID": task.id.uuidString,
                           "KRONOS_AGENT": agent.slug,
                           // Same value as KRONOS_AGENT, under the name the prompt's own shell
                           // contract (RunPromptText.swift) tells the agent is already set,
                           // alongside KRONOS_MCP_ENDPOINT_FILE below — kronos-cli reads both so
                           // its calls reach the instance that launched this harness.
                           "KRONOS_MCP_AGENT": agent.slug]
        if let endpointFilePath { environment["KRONOS_MCP_ENDPOINT_FILE"] = endpointFilePath }
        let spec = ProcessSpec(executablePath: h.executablePath, arguments: argv,
                               environment: environment,
                               workingDirectory: workingDirectory, logPath: logPath)
        do {
            let handle = try spawner.spawn(spec)
            run.pid = handle.pid
            run.logPath = logPath
            handles[run.id] = Tracked(handle: handle, agent: agent, maxMinutes: h.maxMinutes, startedAt: now, logPath: logPath)
            // Forces a save of the pid/logPath mutated directly above (RunStore.start's own save
            // already ran before this point) and renews the lease; no note/artifact, so this
            // heartbeat-shaped call appends no activity row (RunStore.update's own rule).
            try? runs.update(runID: run.id, agent: agent, progress: nil, note: nil, artifactsAdd: [], now: now)
        } catch {
            try? runs.finish(runID: run.id, agent: agent, outcome: .failed,
                             summary: "Could not start: \(error.localizedDescription)",
                             artifactsAdd: [], handoffTo: nil, now: now)
            throw RunLaunchError.spawnFailed(error.localizedDescription)
        }
        return run
    }

    // MARK: - stop

    /// person-initiated: marks the run stopped at once (`RunStore.stop`, no confirmation — B4),
    /// sends SIGTERM, and schedules the SIGKILL escalation on the next `tick`.
    public func stop(runID: UUID, now: Date = Date()) {
        runs.stop(runID: runID, now: now)
        guard let tracked = handles[runID] else { return }
        tracked.handle.terminate()
        stopRequestedAt[runID] = now
    }

    /// The app quitting: SIGTERM every live child and mark its run stopped (B2). Does not wait
    /// for the 10 s SIGKILL escalation — the app is already on its way out.
    public func terminateAllForQuit(now: Date = Date()) {
        for runID in handles.keys { stop(runID: runID, now: now) }
    }

    // MARK: - tick

    /// Called every 15 s (B2) by the real supervisor: sweeps expired leases app-wide, escalates
    /// any pending stop past 10 s to SIGKILL, enforces `maxMinutes` on live runs, renews the
    /// lease of everything still alive, and reaps anything that exited into done/failed.
    public func tick(now: Date = Date()) {
        runs.sweep(now: now)
        for runID in Array(handles.keys) {
            guard let tracked = handles[runID] else { continue }
            let handle = tracked.handle

            if let stoppedAt = stopRequestedAt[runID] {
                if handle.isRunning, now.timeIntervalSince(stoppedAt) >= 10 { handle.kill() }
                if !handle.isRunning {
                    handles.removeValue(forKey: runID)
                    stopRequestedAt.removeValue(forKey: runID)
                }
                continue
            }

            if handle.isRunning {
                if now.timeIntervalSince(tracked.startedAt) >= TimeInterval(tracked.maxMinutes * 60) {
                    handle.terminate()
                    stopRequestedAt[runID] = now
                    continue
                }
                try? runs.update(runID: runID, agent: tracked.agent, progress: nil, note: nil, artifactsAdd: [], now: now)
                continue
            }

            // Exited on its own, not via stop()/maxMinutes above.
            let code = handle.terminationStatus ?? -1
            if code == 0 {
                try? runs.finish(runID: runID, agent: tracked.agent, outcome: .done,
                                 summary: "Exited without reporting", artifactsAdd: [], handoffTo: nil, now: now,
                                 exitedWithoutReporting: true)
            } else {
                try? runs.finish(runID: runID, agent: tracked.agent, outcome: .failed,
                                 summary: Self.logTail(tracked.logPath, lines: 20), artifactsAdd: [], handoffTo: nil, now: now)
            }
            handles.removeValue(forKey: runID)
        }
    }

    private static func logTail(_ path: String, lines: Int) -> String {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return "" }
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        return all.suffix(lines).joined(separator: "\n")
    }
}
