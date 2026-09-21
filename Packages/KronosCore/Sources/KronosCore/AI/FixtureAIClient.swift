// KronosCore/AI — a scripted `AIClient` for tests. `KronosCoreTests`
// never hits the network: inject
// `FixtureAIClient` wherever an `AIClient` or `AIRouting` is needed and hand
// it a script of canned replies or errors, consumed in order.

import Foundation

/// A scripted, deterministic `AIClient`. `send` returns/throws the next
/// unconsumed `Outcome`; calling past the end of the script throws
/// `AIError.noUsableProvider` rather than crashing, so a test that forgets to
/// size its script gets a readable failure instead of a trap.
///
/// An `actor` rather than a lock-guarded class: `AIClient.send` is already
/// `async`, so actor isolation is the async-safe way to serialize the script
/// cursor without reaching for a lock type that Swift 6 forbids calling from
/// an asynchronous context.
public actor FixtureAIClient: AIClient {
    public enum Outcome: Sendable {
        case content(String, finishReason: FinishReason = .stop)
        case failure(AIError)
    }

    public nonisolated let modelID: String
    public nonisolated let dataPolicy: DataPolicy
    private let script: [Outcome]
    private let delay: Duration
    private var cursor = 0
    private var _callLog: [AIRequest] = []

    public init(modelID: String, dataPolicy: DataPolicy = .zeroRetention,
                script: [Outcome], delay: Duration = .zero) {
        self.modelID = modelID
        self.dataPolicy = dataPolicy
        self.script = script
        self.delay = delay
    }

    /// Every request this client has been sent, in order. Used to assert
    /// "no second call to the same model" (T-ERR-2) and similar call-count
    /// invariants.
    public var callLog: [AIRequest] { _callLog }

    /// How many `send` calls have consumed a script entry so far.
    public var callCount: Int { cursor }

    public func send(_ request: AIRequest) async throws -> AIResponse {
        if delay > .zero { try await Task.sleep(for: delay) }
        try Task.checkCancellation()

        _callLog.append(request)
        let index = cursor
        cursor += 1

        guard index < script.count else { throw AIError.noUsableProvider }
        switch script[index] {
        case .content(let text, let finishReason):
            return AIResponse(content: text, finishReason: finishReason,
                              modelRequested: request.model, modelServed: modelID)
        case .failure(let error):
            throw error
        }
    }
}
