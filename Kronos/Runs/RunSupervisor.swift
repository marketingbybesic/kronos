// Kronos v1.2 "harness control" (Phase 2 slice B2). The real transport and timer for
// `RunSupervisorEngine` (Packages/KronosCore/Sources/KronosCore/Runs/RunSupervisorEngine.swift):
// an actual `Process`, a real 15 s tick, a real 0600 log file under a 0700 Runs directory. Same
// split as Kronos/Delivery/WebhookDeliveryController.swift (the transport and the timer here;
// the state machine lives in KronosCore, fully unit-tested there against a fake spawner).

import Foundation
import KronosCore
#if canImport(Darwin)
import Darwin
#endif

/// Wraps a live `Foundation.Process` as `SpawnedProcess`. `terminate()` is Process's own SIGTERM;
/// `kill()` goes straight to the pid since `Process` itself has no SIGKILL method.
private final class RealSpawnedProcess: SpawnedProcess {
    private let process: Process
    init(process: Process) { self.process = process }

    var pid: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }
    var terminationStatus: Int32? { process.isRunning ? nil : process.terminationStatus }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
    }

    func kill() {
        guard process.isRunning else { return }
        #if canImport(Darwin)
        Darwin.kill(process.processIdentifier, SIGKILL)
        #endif
    }
}

private enum RunSupervisorSpawnError: Error { case cannotOpenLog }

/// No shell, exact argv — the executable path is already absolute (pinned in Settings, or found
/// by Find), so this calls it directly rather than through `/usr/bin/env` the way
/// `WebhookDeliveryController`'s transport does for a PATH-relative command. Environment is
/// REPLACED, never inherited (B2); stdout+stderr are merged into one 0600 log file.
private struct RealProcessSpawning: ProcessSpawning {
    func spawn(_ spec: ProcessSpec) throws -> any SpawnedProcess {
        let fm = FileManager.default
        if !fm.fileExists(atPath: spec.logPath) {
            fm.createFile(atPath: spec.logPath, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = FileHandle(forWritingAtPath: spec.logPath) else { throw RunSupervisorSpawnError.cannotOpenLog }
        handle.seekToEndOfFile()

        let p = Process()
        p.executableURL = URL(fileURLWithPath: spec.executablePath)
        p.arguments = spec.arguments
        p.environment = spec.environment
        p.currentDirectoryURL = URL(fileURLWithPath: spec.workingDirectory, isDirectory: true)
        p.standardOutput = handle
        p.standardError = handle
        p.standardInput = FileHandle.nullDevice
        try p.run()
        try? handle.close()
        return RealSpawnedProcess(process: p)
    }
}

/// Persisted "Agents at once" cap (B2): 1...4, default 2. `KronosEnv.defaults` so a hermetic
/// test or snapshot run never reads or writes the person's real preference.
enum RunConcurrencySettings {
    private static let key = "kronos.runs.agentsAtOnce"

    static var agentsAtOnce: Int {
        get {
            let raw = KronosEnv.defaults.object(forKey: key) as? Int
            return min(4, max(1, raw ?? 2))
        }
        set { KronosEnv.defaults.set(min(4, max(1, newValue)), forKey: key) }
    }
}

/// @MainActor, started where `WebhookDeliveryController.start` is called (`MCPAppBinding`), same
/// lifetime: a Kronos-launched run only means anything while MCP itself is up — the harness
/// reports back over MCP, so with the server down there is nowhere for run_update/run_finish to
/// land, and this supervisor's own lease renewal would stop anyway.
@MainActor
final class RunSupervisor {
    private let engine: RunSupervisorEngine
    private let store: any TaskStoring
    private let runs: RunStore
    private var tickTask: Task<Void, Never>?

    init(store: any TaskStoring, runs: RunStore, directory: URL = KronosStore.containerDirectory()) throws {
        self.store = store
        self.runs = runs
        let logDirectory = directory.appendingPathComponent("Runs")
        let fm = FileManager.default
        try fm.createDirectory(at: logDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: logDirectory.path)
        let harness = try HarnessStore(directory: directory)
        // This app instance's own endpoint file, so a spawned harness's kronos-cli reports back
        // HERE (Demo's harness to Demo, the real app's to the real app), never to the default.
        let endpointFile = MCPEndpointFile.defaultDirectory().appendingPathComponent(MCPEndpointFile.fileName).path
        engine = RunSupervisorEngine(runs: runs, harness: harness, spawner: RealProcessSpawning(),
                                     logDirectory: logDirectory, endpointFilePath: endpointFile)
    }

    func start(interval: TimeInterval = 15) {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                if let self { self.engine.tick() }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
    }

    @discardableResult
    func launch(task: KTask, agent: AgentIdentity, model: String? = nil) throws -> KAgentRun {
        let store = self.store
        let runs = self.runs
        return try engine.launch(task: task, agent: agent, cap: RunConcurrencySettings.agentsAtOnce, model: model) { runID in
            RunPrompt.build(task: task, runID: runID, store: store, runs: runs)
        }
    }

    func stopRun(runID: UUID) {
        engine.stop(runID: runID)
    }

    func terminateAllForQuit() {
        engine.terminateAllForQuit()
    }

    /// person-facing text for a refused launch (B1's "Harness changed..." message, B2's cap
    /// pill). `RunSupervisorEngine`/`RunLaunchError` live in KronosCore and never call
    /// `String(localized:)` themselves (see that file's header) — this is the one place the
    /// error becomes prose, for this slice's own Settings UI and for whichever surface later
    /// triggers a launch to read when it needs to explain a refusal.
    static func message(for error: Error) -> String {
        switch error as? RunLaunchError {
        case .harnessUnpinned: return String(localized: "agents.harness.unpinned")
        case .harnessChanged: return String(localized: "agents.harness.changed")
        case .capReached(let cap):
            return KPlural.hr(cap, one: String(localized: "agents.harness.cap.refusal.one"),
                              few: String(localized: "agents.harness.cap.refusal.few"),
                              many: String(localized: "agents.harness.cap.refusal.many"))
        default: return error.localizedDescription
        }
    }
}
