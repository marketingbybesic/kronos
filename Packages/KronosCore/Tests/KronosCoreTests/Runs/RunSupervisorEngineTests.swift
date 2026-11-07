#if os(macOS)
import Testing
import Foundation
import SwiftData
@testable import KronosCore

/// A controllable child process: the test flips `isRunning`/`terminationStatus` directly instead
/// of spawning anything real.
private final class FakeProcess: SpawnedProcess {
    let pid: Int32
    var isRunning = true
    var terminationStatus: Int32?
    var terminateCalled = false
    var killCalled = false

    init(pid: Int32) { self.pid = pid }

    func terminate() { terminateCalled = true }
    func kill() { killCalled = true }

    func exit(_ code: Int32) {
        isRunning = false
        terminationStatus = code
    }
}

private final class FakeSpawner: ProcessSpawning {
    private var nextPid: Int32 = 1000
    var shouldThrow = false
    var spawned: [(spec: ProcessSpec, process: FakeProcess)] = []

    func spawn(_ spec: ProcessSpec) throws -> any SpawnedProcess {
        if shouldThrow { throw NSError(domain: "fake-spawner", code: 1) }
        let p = FakeProcess(pid: nextPid)
        nextPid += 1
        spawned.append((spec, p))
        return p
    }
}

@MainActor
@Suite struct RunSupervisorEngineTests {

    private struct Rig {
        let agentRig: AgentRig
        let harness: HarnessStore
        let spawner: FakeSpawner
        let engine: RunSupervisorEngine
        let logDirectory: URL
    }

    private func rig() throws -> Rig {
        let agentRig = try AgentRig()
        let harness = HarnessStore(context: ModelContext(try KronosRunsStore.makeContainer(inMemory: true)))
        let spawner = FakeSpawner()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("run-supervisor-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let engine = RunSupervisorEngine(runs: agentRig.runs, harness: harness, spawner: spawner, logDirectory: dir)
        return Rig(agentRig: agentRig, harness: harness, spawner: spawner, engine: engine, logDirectory: dir)
    }

    // MARK: - argv substitution (B5)

    @Test func argvSubstitutionOnlyReplacesAnExactPlaceholderElement() {
        let argv = ["-p", "say {prompt} now", "{prompt}", "--flag"]
        let out = HarnessArgv.substituting(argv, prompt: "hello world")
        #expect(out == ["-p", "say {prompt} now", "hello world", "--flag"],
                "{prompt} embedded in a larger string is left alone; only the exact element is replaced")
        // positive control: no placeholder element at all leaves every element untouched.
        #expect(HarnessArgv.substituting(["-p", "fixed"], prompt: "anything") == ["-p", "fixed"])
    }

    @Test func argvSubstitutionInsertsThePerSlugModelFlagBeforeThePromptElement() {
        // omp and claude both read the long flag; codex reads the short one.
        #expect(HarnessArgv.substituting(["-p", "--no-session", "{prompt}"], prompt: "hi", model: "gpt-5", slug: "omp")
                == ["-p", "--no-session", "--model", "gpt-5", "hi"])
        #expect(HarnessArgv.substituting(["-p", "{prompt}"], prompt: "hi", model: "opus", slug: "claude")
                == ["-p", "--model", "opus", "hi"])
        #expect(HarnessArgv.substituting(["exec", "{prompt}"], prompt: "hi", model: "o3", slug: "codex")
                == ["exec", "-m", "o3", "hi"])
        // an unlisted slug falls back to the long flag, same as HarnessDefaults.modelFlag itself.
        #expect(HarnessArgv.substituting(["{prompt}"], prompt: "hi", model: "x", slug: "mystery-agent")
                == ["--model", "x", "hi"])
        // positive control: nil model leaves the composed argv byte-identical to calling with none at all.
        #expect(HarnessArgv.substituting(["-p", "{prompt}"], prompt: "hi", model: nil, slug: "omp") == ["-p", "hi"])
        #expect(HarnessArgv.substituting(["-p", "{prompt}"], prompt: "hi") == ["-p", "hi"])
        // blank/whitespace-only model is also "Auto": no flag inserted.
        #expect(HarnessArgv.substituting(["-p", "{prompt}"], prompt: "hi", model: "   ", slug: "omp") == ["-p", "hi"])
    }

    // MARK: - launch preconditions

    @Test func launchingWithNoHarnessPinnedThrowsUnpinned() throws {
        let r = try rig()
        let a = r.agentRig.agent("claude")
        let t = r.agentRig.store.createNoUndo(title: "Ship it")
        #expect(throws: RunLaunchError.harnessUnpinned) {
            try r.engine.launch(task: t, agent: a, cap: 2) { _ in "prompt" }
        }
        #expect(r.spawner.spawned.isEmpty, "never spawns when the harness is not pinned")
    }

    @Test func launchingWithAMissingPinnedBinaryThrowsChanged() throws {
        let r = try rig()
        let a = r.agentRig.agent("claude")
        r.harness.pin(agentID: a.agentID, executablePath: "/no/such/binary-\(UUID().uuidString)", argvTemplate: ["{prompt}"])
        let t = r.agentRig.store.createNoUndo(title: "Ship it")
        #expect(throws: RunLaunchError.harnessChanged) {
            try r.engine.launch(task: t, agent: a, cap: 2) { _ in "prompt" }
        }
    }

    @Test func launchingPastTheCapRefusesWithoutClaimingTheTask() throws {
        let r = try rig()
        let a = r.agentRig.agent("claude"), b = r.agentRig.agent("codex")
        r.harness.pin(agentID: a.agentID, executablePath: "/bin/sh", argvTemplate: ["{prompt}"])
        r.harness.pin(agentID: b.agentID, executablePath: "/bin/sh", argvTemplate: ["{prompt}"])
        let t1 = r.agentRig.store.createNoUndo(title: "One")
        let t2 = r.agentRig.store.createNoUndo(title: "Two")
        _ = try r.engine.launch(task: t1, agent: a, cap: 1) { _ in "prompt" }
        #expect(throws: RunLaunchError.capReached(1)) {
            try r.engine.launch(task: t2, agent: b, cap: 1) { _ in "prompt" }
        }
        #expect(r.agentRig.runs.activeRun(taskID: t2.id) == nil, "the refused task is never claimed")
        // positive control: raising the cap lets the second one through.
        #expect(throws: Never.self) { try r.engine.launch(task: t2, agent: b, cap: 2) { _ in "prompt" } }
    }

    @Test func launchInjectsTheEndpointFileOfitsOwnInstanceIntoTheChildEnvironment() throws {
        let agentRig = try AgentRig()
        let harness = HarnessStore(context: ModelContext(try KronosRunsStore.makeContainer(inMemory: true)))
        let spawner = FakeSpawner()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("run-supervisor-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let engine = RunSupervisorEngine(runs: agentRig.runs, harness: harness, spawner: spawner,
                                         logDirectory: dir, endpointFilePath: "/tmp/demo-secrets/mcp_endpoint.json")
        let a = agentRig.agent("claude")
        harness.pin(agentID: a.agentID, executablePath: "/bin/sh", argvTemplate: ["{prompt}"])
        let t = agentRig.store.createNoUndo(title: "Report back here")
        _ = try engine.launch(task: t, agent: a, cap: 2) { _ in "prompt" }
        let env = try #require(spawner.spawned.first?.spec.environment)
        #expect(env["KRONOS_MCP_ENDPOINT_FILE"] == "/tmp/demo-secrets/mcp_endpoint.json",
                "a harness must report to the instance that launched it, not kronos-cli's default")
        #expect(env["KRONOS_MCP_AGENT"] == a.slug,
                "kronos-cli reads KRONOS_MCP_AGENT; the prompt's shell contract promises it is set")
        #expect(env["KRONOS_AGENT"] == a.slug)
        // positive control: an engine built WITHOUT an endpoint path (the hermetic default) adds no key.
        let bare = try rig()
        bare.harness.pin(agentID: bare.agentRig.agent("codex").agentID, executablePath: "/bin/sh", argvTemplate: ["{prompt}"])
        let t2 = bare.agentRig.store.createNoUndo(title: "Bare")
        _ = try bare.engine.launch(task: t2, agent: bare.agentRig.agent("codex"), cap: 2) { _ in "p" }
        #expect(bare.spawner.spawned.first?.spec.environment["KRONOS_MCP_ENDPOINT_FILE"] == nil)
    }

    // MARK: - model (handoff-ui slice)

    @Test func launchWithAModelAppendsThePerSlugFlagBeforeThePromptArgument() throws {
        let r = try rig()
        let a = r.agentRig.agent("codex")
        r.harness.pin(agentID: a.agentID, executablePath: "/bin/sh", argvTemplate: ["exec", "{prompt}"])
        let t = r.agentRig.store.createNoUndo(title: "Ship it")
        _ = try r.engine.launch(task: t, agent: a, cap: 2, model: "o3") { _ in "built prompt" }
        let spec = try #require(r.spawner.spawned.first?.spec)
        #expect(spec.arguments == ["exec", "-m", "o3", "built prompt"])
        // positive control: omitting model (the default) composes argv exactly as before this slice.
        let b = r.agentRig.agent("claude")
        r.harness.pin(agentID: b.agentID, executablePath: "/bin/sh", argvTemplate: ["-p", "{prompt}"])
        let t2 = r.agentRig.store.createNoUndo(title: "Ship it too")
        _ = try r.engine.launch(task: t2, agent: b, cap: 2) { _ in "built prompt 2" }
        #expect(r.spawner.spawned.last?.spec.arguments == ["-p", "built prompt 2"])
    }

    // MARK: - exit handling (B5)

    @Test func exitZeroWhileRunningFinishesDoneWithTheFallbackSummary() throws {
        let r = try rig()
        let a = r.agentRig.agent("claude")
        r.harness.pin(agentID: a.agentID, executablePath: "/bin/sh", argvTemplate: ["{prompt}"])
        let t = r.agentRig.store.createNoUndo(title: "Ship it")
        let run = try r.engine.launch(task: t, agent: a, cap: 2) { runID in "run \(runID)" }
        let (spec, process) = try #require(r.spawner.spawned.first)
        #expect(spec.executablePath == "/bin/sh")
        #expect(spec.arguments == ["run \(run.id)"], "the placeholder element carries the built prompt")
        #expect(r.agentRig.runs.run(id: run.id)?.pid == process.pid, "the pid is attached to the run")

        process.exit(0)
        r.engine.tick(now: r.agentRig.clock)
        let after = try #require(r.agentRig.runs.run(id: run.id))
        #expect(after.stateRaw == "done")
        #expect(after.summary == "Exited without reporting")
        #expect(after.exitedWithoutReporting, "Review-next reads this flag to avoid claiming the agent 'says it is done'")
    }

    @Test func nonzeroExitFinishesFailedWithTheLastTwentyLogLines() throws {
        let r = try rig()
        let a = r.agentRig.agent("claude")
        r.harness.pin(agentID: a.agentID, executablePath: "/bin/sh", argvTemplate: ["{prompt}"])
        let t = r.agentRig.store.createNoUndo(title: "Ship it")
        let run = try r.engine.launch(task: t, agent: a, cap: 2) { _ in "prompt" }
        let logPath = try #require(r.agentRig.runs.run(id: run.id)?.logPath)
        let lines = (1...25).map { "line \($0)" }
        try lines.joined(separator: "\n").write(toFile: logPath, atomically: true, encoding: .utf8)

        let (_, process) = try #require(r.spawner.spawned.first)
        process.exit(17)
        r.engine.tick(now: r.agentRig.clock)
        let after = try #require(r.agentRig.runs.run(id: run.id))
        #expect(after.stateRaw == "failed")
        #expect(!after.summary.contains("line 5"), "only the LAST 20 lines are kept")
        #expect(after.summary.contains("line 25"), "the most recent lines are kept")
        #expect(after.summary.components(separatedBy: "\n").count == 20)
        // positive control for exitedWithoutReporting: a REAL failure path leaves it false.
        #expect(!after.exitedWithoutReporting)
    }

    @Test func maxMinutesElapsedTerminatesALiveProcessButNotYetSigkill() throws {
        let r = try rig()
        let a = r.agentRig.agent("claude")
        r.harness.pin(agentID: a.agentID, executablePath: "/bin/sh", argvTemplate: ["{prompt}"], maxMinutes: 5)
        let t = r.agentRig.store.createNoUndo(title: "Ship it")
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try r.engine.launch(task: t, agent: a, cap: 2, now: t0) { _ in "prompt" }
        let (_, process) = try #require(r.spawner.spawned.first)

        r.engine.tick(now: t0.addingTimeInterval(4 * 60))
        #expect(!process.terminateCalled, "not past maxMinutes yet")

        r.engine.tick(now: t0.addingTimeInterval(5 * 60 + 1))
        #expect(process.terminateCalled, "past maxMinutes: SIGTERM sent")
        #expect(!process.killCalled, "no SIGKILL before the 10 s grace period")
    }

    // MARK: - stop / escalation

    @Test func stopMarksTheRunStoppedAtOnceAndNeverAsksAgain() throws {
        let r = try rig()
        let a = r.agentRig.agent("claude")
        r.harness.pin(agentID: a.agentID, executablePath: "/bin/sh", argvTemplate: ["{prompt}"])
        let t = r.agentRig.store.createNoUndo(title: "Ship it")
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let run = try r.engine.launch(task: t, agent: a, cap: 2, now: t0) { _ in "prompt" }
        let (_, process) = try #require(r.spawner.spawned.first)

        r.engine.stop(runID: run.id, now: t0)
        #expect(process.terminateCalled)
        #expect(r.agentRig.runs.run(id: run.id)?.stateRaw == "stopped", "stop acts at once, no confirmation step")
    }

    @Test func stopEscalatesToSigkillAfterTenSecondsIfStillAlive() throws {
        let r = try rig()
        let a = r.agentRig.agent("claude")
        r.harness.pin(agentID: a.agentID, executablePath: "/bin/sh", argvTemplate: ["{prompt}"])
        let t = r.agentRig.store.createNoUndo(title: "Ship it")
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let run = try r.engine.launch(task: t, agent: a, cap: 2, now: t0) { _ in "prompt" }
        let (_, process) = try #require(r.spawner.spawned.first)
        r.engine.stop(runID: run.id, now: t0)

        r.engine.tick(now: t0.addingTimeInterval(9))
        #expect(!process.killCalled, "within the grace period")

        r.engine.tick(now: t0.addingTimeInterval(11))
        #expect(process.killCalled, "still alive past 10 s: SIGKILL")
    }

    @Test func terminateAllForQuitStopsEveryLiveRun() throws {
        let r = try rig()
        let a = r.agentRig.agent("claude"), b = r.agentRig.agent("codex")
        r.harness.pin(agentID: a.agentID, executablePath: "/bin/sh", argvTemplate: ["{prompt}"])
        r.harness.pin(agentID: b.agentID, executablePath: "/bin/sh", argvTemplate: ["{prompt}"])
        let t1 = r.agentRig.store.createNoUndo(title: "One")
        let t2 = r.agentRig.store.createNoUndo(title: "Two")
        let run1 = try r.engine.launch(task: t1, agent: a, cap: 2) { _ in "prompt" }
        let run2 = try r.engine.launch(task: t2, agent: b, cap: 2) { _ in "prompt" }

        r.engine.terminateAllForQuit()
        #expect(r.agentRig.runs.run(id: run1.id)?.stateRaw == "stopped")
        #expect(r.agentRig.runs.run(id: run2.id)?.stateRaw == "stopped")
        #expect(r.spawner.spawned.allSatisfy { $0.process.terminateCalled })
    }

    // MARK: - spawn failure

    @Test func aSpawnFailureFinishesTheClaimedRunFailedRatherThanLeavingItClaimed() throws {
        let r = try rig()
        let a = r.agentRig.agent("claude")
        r.harness.pin(agentID: a.agentID, executablePath: "/bin/sh", argvTemplate: ["{prompt}"])
        r.spawner.shouldThrow = true
        let t = r.agentRig.store.createNoUndo(title: "Ship it")
        #expect(throws: RunLaunchError.self) {
            try r.engine.launch(task: t, agent: a, cap: 2) { _ in "prompt" }
        }
        #expect(r.agentRig.runs.activeRun(taskID: t.id) == nil, "a failed spawn never leaves the task claimed")
    }
}
#endif
