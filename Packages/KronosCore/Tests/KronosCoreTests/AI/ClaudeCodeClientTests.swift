import Testing
import Foundation
@testable import KronosCore

/// Lock-guarded flag/counter, mirroring `CheckFlag` in AppleIntelligenceClientTests.swift —
/// `@Sendable` closures cannot mutate a plain captured `var` under Swift's concurrency checking.
private final class CallRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var terminated = false
    func markTerminated() { lock.withLock { terminated = true } }
    var wasTerminated: Bool { lock.withLock { terminated } }
}

/// `SubprocessRunning` stub: never spawns a real process. `behavior` decides what `run` does;
/// `hang` sleeps past the caller's budget and, on cancellation, marks `record.wasTerminated` —
/// the same signal a real `ProcessRunner.onCancel -> terminate()` would produce, just without an
/// actual `Process`.
private struct FixtureRunner: SubprocessRunning {
    enum Behavior {
        case success(stdout: Data, exitCode: Int32 = 0)
        case failure(exitCode: Int32, stderr: Data)
        case hang
        case missing
    }
    let behavior: Behavior
    let record: CallRecord

    func run(executablePath: String, arguments: [String], stdin: String) async throws
        -> (stdout: Data, stderr: Data, exitCode: Int32) {
        switch behavior {
        case .success(let stdout, let exitCode):
            return (stdout, Data(), exitCode)
        case .failure(let exitCode, let stderr):
            return (Data(), stderr, exitCode)
        case .missing:
            throw AIError.noUsableProvider
        case .hang:
            return try await withTaskCancellationHandler {
                try await Task.sleep(for: .seconds(60))
                return (Data(), Data(), 0)
            } onCancel: {
                record.markTerminated()
            }
        }
    }
}

private func envelope(result: String, isError: Bool = false, apiErrorStatus: Int? = nil) -> Data {
    var obj: [String: Any] = ["type": "result", "is_error": isError, "result": result]
    if let apiErrorStatus { obj["api_error_status"] = apiErrorStatus }
    return try! JSONSerialization.data(withJSONObject: obj)
}

private func makeRequest(budgetSeconds: Double = 5) -> AIRequest {
    AIRequest(model: "claude-sonnet-5",
              messages: [.system("you are terse"), .user("Return only {\"ok\":true}")],
              kind: .triage,
              budgetSeconds: budgetSeconds)
}

struct ClaudeCodeClientTests {

    // MARK: - parse -> content success

    @Test func successfulRunParsesEnvelopeIntoContent() async throws {
        let record = CallRecord()
        let stdout = envelope(result: "{\"ok\":true}")
        let runner = FixtureRunner(behavior: .success(stdout: stdout), record: record)
        let client = ClaudeCodeClient(modelID: "claude-sonnet-5", runner: runner)
        let response = try await client.send(makeRequest())
        #expect(response.content == "{\"ok\":true}")
        #expect(response.finishReason == .stop)
        #expect(response.modelServed == "claude-sonnet-5")
    }

    // MARK: - nonzero exit -> mapped error

    @Test func structuredErrorEnvelopeMapsToHTTPError() async throws {
        let record = CallRecord()
        // Measured shape (2026-10-09): exit 1, valid JSON, is_error:true, api_error_status:403.
        let stdout = envelope(result: "org has disabled subscription access", isError: true, apiErrorStatus: 403)
        let runner = FixtureRunner(behavior: .success(stdout: stdout, exitCode: 1), record: record)
        let client = ClaudeCodeClient(modelID: "claude-sonnet-5", runner: runner)
        await #expect(throws: AIError.http(403)) {
            try await client.send(makeRequest())
        }
    }

    @Test func structuredErrorWithoutStatusMapsToBadJSON() async throws {
        let record = CallRecord()
        let stdout = envelope(result: "something went wrong", isError: true)
        let runner = FixtureRunner(behavior: .success(stdout: stdout, exitCode: 1), record: record)
        let client = ClaudeCodeClient(modelID: "claude-sonnet-5", runner: runner)
        do {
            _ = try await client.send(makeRequest())
            Issue.record("expected badJSON")
        } catch let error as AIError {
            guard case .badJSON(let prefix) = error else {
                Issue.record("expected badJSON, got \(error)"); return
            }
            #expect(prefix.contains("something went wrong"))
        }
    }

    @Test func nonzeroExitWithUnparseableOutputMapsToBadJSON() async throws {
        let record = CallRecord()
        let runner = FixtureRunner(behavior: .failure(exitCode: 127, stderr: Data("command not found".utf8)), record: record)
        let client = ClaudeCodeClient(modelID: "claude-sonnet-5", runner: runner)
        do {
            _ = try await client.send(makeRequest())
            Issue.record("expected badJSON")
        } catch let error as AIError {
            guard case .badJSON(let prefix) = error else {
                Issue.record("expected badJSON, got \(error)"); return
            }
            #expect(prefix.contains("command not found"))
        }
    }

    // MARK: - malformed output -> badJSON, prefix truncated

    @Test func malformedOutputMapsToBadJSONWithTruncatedPrefix() async throws {
        let record = CallRecord()
        let garbage = Data(String(repeating: "x", count: 500).utf8)
        let runner = FixtureRunner(behavior: .success(stdout: garbage), record: record)
        let client = ClaudeCodeClient(modelID: "claude-sonnet-5", runner: runner)
        do {
            _ = try await client.send(makeRequest())
            Issue.record("expected badJSON")
        } catch let error as AIError {
            guard case .badJSON(let prefix) = error else {
                Issue.record("expected badJSON, got \(error)"); return
            }
            #expect(prefix.count <= 200)
        }
    }

    // MARK: - budget exceeded -> timeout + terminate() called

    @Test func budgetExceededTimesOutAndTerminatesTheSubprocess() async throws {
        let record = CallRecord()
        let runner = FixtureRunner(behavior: .hang, record: record)
        let client = ClaudeCodeClient(modelID: "claude-sonnet-5", runner: runner)
        await #expect(throws: AIError.timeout(budgetSeconds: 0.05)) {
            try await client.send(makeRequest(budgetSeconds: 0.05))
        }
        // `AIRouter.raced` cancels the losing task after it resolves the race by timeout; give
        // the cancellation handler a moment to run before asserting on it.
        try await Task.sleep(for: .milliseconds(50))
        #expect(record.wasTerminated)
    }

    // MARK: - missing binary -> noUsableProvider

    @Test func missingExecutableMapsToNoUsableProvider() async throws {
        let record = CallRecord()
        let runner = FixtureRunner(behavior: .missing, record: record)
        let client = ClaudeCodeClient(modelID: "claude-sonnet-5", executablePath: "/nonexistent/claude", runner: runner)
        await #expect(throws: AIError.noUsableProvider) {
            try await client.send(makeRequest())
        }
    }

    // MARK: - task cancellation -> terminate() called

    @Test func parentTaskCancellationTerminatesTheSubprocess() async throws {
        let record = CallRecord()
        let runner = FixtureRunner(behavior: .hang, record: record)
        let client = ClaudeCodeClient(modelID: "claude-sonnet-5", runner: runner)
        let task = Task {
            try await client.send(makeRequest(budgetSeconds: 30))
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        _ = try? await task.value
        try await Task.sleep(for: .milliseconds(50))
        #expect(record.wasTerminated)
    }
}
