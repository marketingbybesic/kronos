// The Claude-subscription `AIClient`: shells out to the `claude` CLI (`-p`, one-shot,
// `--output-format json`) instead of an HTTP gateway, so the person's own Claude Code
// subscription pays for inference rather than a separate API key. Mirrors the
// `HTTPTransport`/`KeyProviding` seams `OpenAICompatibleClient` uses (GhostCLIClient.swift) —
// here the seam is a subprocess, not a socket, so tests never spawn a real process.
//
// Real CLI envelope, measured 2026-10-09 against `/opt/homebrew/bin/claude -p --model
// claude-sonnet-5 --output-format json --no-session-persistence 'Return only {"ok":true}'`
// (this machine's org has Claude subscription CLI access disabled, so BOTH claude-sonnet-5 and
// claude-haiku-4-5 answered identically with `is_error:true, api_error_status:403,
// api_error_code:"oauth_not_allowed_for_organization"` — a policy block, not a decode failure):
//   {"type":"result","is_error":true,"subtype":"success","api_error_status":403,
//    "api_error_code":"oauth_not_allowed_for_organization","result":"<human-readable message>",
//    "duration_ms":419,"session_id":"…", …}
// On success the same top-level shape applies with `is_error:false` and `result` holding the
// assistant's plain text reply (never reasoning_content — the CLI's JSON mode does not expose
// it). The decoder below reads exactly these five fields and ignores the rest (usage, cost,
// subagent stats, …), tolerantly, the same way `FinishReason.init(wire:)` tolerates unknown
// provider strings.

import Foundation

// MARK: - Injectable subprocess seam

/// The one process-spawn seam `ClaudeCodeClient` uses, mirroring `HTTPTransport`
/// (GhostCLIClient.swift): `ProcessRunner` conforms via Foundation `Process`; tests inject a
/// stub that never spawns a real process.
public protocol SubprocessRunning: Sendable {
    func run(executablePath: String, arguments: [String], stdin: String) async throws
        -> (stdout: Data, stderr: Data, exitCode: Int32)
}

/// Thread-safe mutable box backing one `Process` invocation. Mirrors `RaceGate`
/// (AIRouter+Deadline.swift) — a lock-guarded `@unchecked Sendable` class is this codebase's
/// existing pattern for a continuation plus cancellable work that outlives one stack frame.
private final class ProcessRunBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var stdoutData = Data()
    private var stderrData = Data()
    private var continuation: CheckedContinuation<(stdout: Data, stderr: Data, exitCode: Int32), Error>?
    private var finished = false

    func setProcess(_ p: Process) {
        lock.lock(); process = p; lock.unlock()
    }

    func install(_ c: CheckedContinuation<(stdout: Data, stderr: Data, exitCode: Int32), Error>) {
        lock.lock(); continuation = c; lock.unlock()
    }

    func appendStdout(_ d: Data) { lock.lock(); stdoutData.append(d); lock.unlock() }
    func appendStderr(_ d: Data) { lock.lock(); stderrData.append(d); lock.unlock() }

    func finish(exitCode: Int32) {
        lock.lock()
        guard !finished, let continuation else { lock.unlock(); return }
        finished = true
        let out = stdoutData, err = stderrData
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: (out, err, exitCode))
    }

    func fail(_ error: Error) {
        lock.lock()
        guard !finished, let continuation else { lock.unlock(); return }
        finished = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(throwing: error)
    }

    /// Called from `withTaskCancellationHandler`'s `onCancel`, which can run before `process`
    /// is installed (cancelled before `process.run()`) — reading under the lock makes that race
    /// safe: `run()` below never calls `process.run()` before `setProcess` has already stored it.
    func terminate() {
        lock.lock(); let p = process; lock.unlock()
        p?.terminate()
    }
}

/// `Process`-backed `SubprocessRunning`. `onCancel` calls `terminate()` so a parent-task
/// cancellation (Impuls's 4 s crossfade window, a budget race) kills the child process instead
/// of leaking it.
public struct ProcessRunner: SubprocessRunning {
    public init() {}

    public func run(executablePath: String, arguments: [String], stdin: String) async throws
        -> (stdout: Data, stderr: Data, exitCode: Int32) {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw AIError.noUsableProvider
        }
        let box = ProcessRunBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(stdout: Data, stderr: Data, exitCode: Int32), Error>) in
                box.install(continuation)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = arguments
                let stdinPipe = Pipe()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardInput = stdinPipe
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                box.setProcess(process)

                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty { handle.readabilityHandler = nil } else { box.appendStdout(data) }
                }
                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty { handle.readabilityHandler = nil } else { box.appendStderr(data) }
                }
                process.terminationHandler = { finished in
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    box.finish(exitCode: finished.terminationStatus)
                }
                do {
                    try process.run()
                    let input = stdin.data(using: .utf8) ?? Data()
                    stdinPipe.fileHandleForWriting.write(input)
                    try? stdinPipe.fileHandleForWriting.close()
                } catch {
                    box.fail(error)
                }
            }
        } onCancel: {
            box.terminate()
        }
    }
}

// MARK: - ClaudeCodeClient

/// `AIClient` backed by the `claude` CLI's one-shot `-p` mode instead of an HTTP gateway. Data
/// leaves the Mac (Anthropic's API, same as any other hosted provider) — `dataPolicy` defaults
/// to `.unknown`, exactly like `OpenAICompatibleClient`'s default, never `.onDevice`/private-only.
public struct ClaudeCodeClient: AIClient {
    public let modelID: String
    public let dataPolicy: DataPolicy
    let executablePath: String
    let runner: SubprocessRunning

    public init(modelID: String,
                dataPolicy: DataPolicy = .unknown,
                executablePath: String = "/opt/homebrew/bin/claude",
                runner: SubprocessRunning = ProcessRunner()) {
        self.modelID = modelID
        self.dataPolicy = dataPolicy
        self.executablePath = executablePath
        self.runner = runner
    }

    public func send(_ request: AIRequest) async throws -> AIResponse {
        let baseArgs = ["-p", "--model", modelID, "--output-format", "json", "--no-session-persistence",
                    "--setting-sources", "", "--strict-mcp-config", "--tools", ""]
        let systemArgs: [String]
        if let system = request.messages.first(where: { $0.role == "system" })?.content, !system.isEmpty {
            systemArgs = ["--system-prompt", system]
        } else {
            systemArgs = []
        }
        // `let`, not `var`: captured below inside `AIRouter.raced`'s concurrently-executing
        // closure — Swift 6 strict concurrency flags a captured mutable var there even though
        // the mutation above always happens-before the closure runs (SendableClosureCaptures).
        let args = baseArgs + systemArgs
        let stdin = request.messages
            .filter { $0.role == "user" }
            .map(\.content)
            .joined(separator: "\n\n")

        let started = ContinuousClock.now
        let result: (stdout: Data, stderr: Data, exitCode: Int32)
        do {
            // Self-enforced: impulsPick's outer chain (AI-001) and triage/retriage's
            // `chainBudgetSeconds` wrapper may or may not actually reach this call depending on
            // the caller, so this client never trusts an outer deadline to exist — it races its
            // own subprocess against `request.budgetSeconds` and terminates the loser itself
            // (`ProcessRunner`'s `onCancel`), exactly like `AIRouter.raced` already does for a
            // whole candidate chain.
            result = try await AIRouter.raced(seconds: request.budgetSeconds) {
                try await runner.run(executablePath: executablePath, arguments: args, stdin: stdin)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AIError {
            throw error   // .timeout from the race, or .noUsableProvider from the runner's own guard
        } catch {
            throw AIError.badJSON(prefix: "subprocess failed to launch: " + String(String(describing: error).prefix(160)))
        }

        let elapsed = (ContinuousClock.now - started).components
        let latencyMS = Int(elapsed.seconds) * 1000 + Int(elapsed.attoseconds / 1_000_000_000_000_000)

        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: result.stdout) else {
            // No parseable JSON at all. The CLI still exits non-zero on a structured error (see
            // header comment), so an unparseable body plus a non-zero exit is a launch/transport
            // failure, not a schema mismatch — surface stderr (or stdout, if stderr is empty)
            // as the closest thing to a diagnosable message, still capped at 200 chars.
            let source = result.stderr.isEmpty ? result.stdout : result.stderr
            throw AIError.badJSON(prefix: String(decoding: source.prefix(200), as: UTF8.self))
        }

        if envelope.isError {
            if let status = envelope.apiErrorStatus {
                throw AIError.http(status)
            }
            let message = envelope.result ?? envelope.apiErrorCode ?? "claude cli error"
            throw AIError.badJSON(prefix: String(message.prefix(200)))
        }

        guard let content = envelope.result, !content.isEmpty else {
            throw AIError.badJSON(prefix: "empty result")
        }

        return AIResponse(content: content, finishReason: .stop,
                          modelRequested: request.model, modelServed: modelID,
                          latencyMS: latencyMS)
    }

    /// The subset of the CLI's `--output-format json` envelope this client reads. Every field
    /// is decoded tolerantly (`decodeIfPresent`): an envelope shape drift on the person's own CLI
    /// should fall through to the "no parseable JSON" / "empty result" paths above rather than
    /// crash the decoder.
    private struct Envelope: Decodable {
        let type: String?
        let isError: Bool
        let result: String?
        let apiErrorStatus: Int?
        let apiErrorCode: String?

        enum CodingKeys: String, CodingKey {
            case type, result
            case isError = "is_error"
            case apiErrorStatus = "api_error_status"
            case apiErrorCode = "api_error_code"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try c.decodeIfPresent(String.self, forKey: .type)
            isError = try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false
            result = try c.decodeIfPresent(String.self, forKey: .result)
            apiErrorStatus = try c.decodeIfPresent(Int.self, forKey: .apiErrorStatus)
            apiErrorCode = try c.decodeIfPresent(String.self, forKey: .apiErrorCode)
        }
    }
}
