// The default provider client: OpenAI-compatible POST against the GhostCLI
// gateway (`https://ghostcli.dev/v1`). Transport and key access are both
// injected protocols so `KronosCoreTests` never touches the network or the
// real Keychain.

import Foundation

// MARK: - Injectable transport

/// The one HTTP seam `GhostCLIClient` uses. `URLSession` conforms via the
/// extension below; tests inject a stub that never leaves the process.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPTransport {
    public func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request)
    }
}

// MARK: - Injectable key access

/// Reads the bearer token for a provider, keyed by a logical name (e.g. "ai.openrouter") —
/// not a raw Keychain service string any more. The real implementation reads it from the
/// app-owned `SecretStoring` seam (Secrets/**), so this is the only place `GhostCLIClient`
/// touches a secret; tests inject a fixed string so no Keychain prompt ever appears in CI.
public protocol KeyProviding: Sendable {
    func key(service: String) -> String?
}

/// `KeyProviding` backed by the app-owned secret store. Never logs, prints, or otherwise
/// surfaces the retrieved secret. `service`
/// here is the logical name inside `SecretStoring`, e.g. `AIProvider.keychainService` —
/// an item this app wrote itself, never a legacy item some other build or tool created.
public struct KeychainKeyProvider: KeyProviding {
    private let store: any SecretStoring

    public init(store: any SecretStoring = KeychainSecretStore()) {
        self.store = store
    }

    public func key(service: String) -> String? {
        store.read(service)
    }
}

// MARK: - GhostCLIClient

/// The default `AIClient`: OpenAI-compatible chat completions against the
/// GhostCLI gateway. `stream` is always encoded `false` via `AIRequest`
/// (frozen contract), and `parseBody` still sniffs for an SSE payload as the
/// defensive half of that mitigation.
public struct GhostCLIClient: AIClient {
    public static let defaultBaseURL = URL(string: "https://ghostcli.dev/v1")!
    /// Logical name inside the app-owned secret store (see `KeyProviding`). Not a raw
    /// Keychain service string any more — that string lives on as `legacyKeychainService`,
    /// read only by the explicit "use the key already in your Keychain" adopt action.
    public static let keychainService = "ai.ghostcli"
    /// The Keychain service an older build wrote the GhostCLI key under directly, before the
    /// app-owned secret store existed. Read-only, adopt-action only — never written again.
    public static let legacyKeychainService = "ghostcli_api"

    public let modelID: String
    public let dataPolicy: DataPolicy
    let baseURL: URL
    let keyProvider: KeyProviding
    let keyService: String
    let transport: HTTPTransport
    /// Additional fixed headers merged onto every request (e.g. OpenRouter's
    /// `HTTP-Referer` / `X-Title`, which are harmless against any other
    /// OpenAI-compatible gateway). Empty by default so every existing call
    /// site is unaffected.
    let extraHeaders: [String: String]

    public init(modelID: String,
                dataPolicy: DataPolicy = .unknown,
                baseURL: URL = GhostCLIClient.defaultBaseURL,
                keyProvider: KeyProviding = KeychainKeyProvider(),
                keyService: String = GhostCLIClient.keychainService,
                transport: HTTPTransport = URLSession.shared,
                extraHeaders: [String: String] = [:]) {
        self.modelID = modelID
        self.dataPolicy = dataPolicy
        self.baseURL = baseURL
        self.keyProvider = keyProvider
        self.keyService = keyService
        self.transport = transport
        self.extraHeaders = extraHeaders
    }

    public func send(_ request: AIRequest) async throws -> AIResponse {
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        if let key = keyProvider.key(service: keyService) {
            urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        for (field, value) in extraHeaders {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        urlRequest.timeoutInterval = request.budgetSeconds
        do {
            var wire = request
            // Some OpenRouter reasoning models think for 30-270 s before the JSON and blow the
            // budget; the switch is only sent to OpenRouter (see AIRequest).
            if wire.reasoning == nil, baseURL.host?.contains("openrouter.ai") == true {
                wire.reasoning = AIRequest.ReasoningControl(enabled: false)
            }
            urlRequest.httpBody = try wire.encodedBody()
        } catch {
            throw AIError.badJSON(prefix: "failed to encode request")
        }

        let started = ContinuousClock.now
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await withTaskCancellationHandler {
                try await transport.send(urlRequest)
            } onCancel: {
                // URLSession-backed transports cancel their in-flight task on
                // their own when the surrounding Task is cancelled; injected
                // test transports have nothing to cancel.
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw AIError.timeout(budgetSeconds: request.budgetSeconds)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw AIError.http(0)
        }

        guard let http = response as? HTTPURLResponse else { throw AIError.http(0) }
        guard (200..<300).contains(http.statusCode) else {
            throw AIError.http(http.statusCode)
        }

        let elapsed = (ContinuousClock.now - started).components
        let latencyMS = Int(elapsed.seconds) * 1000 + Int(elapsed.attoseconds / 1_000_000_000_000_000)
        let contentType = http.value(forHTTPHeaderField: "Content-Type")
        return try Self.parseBody(data, modelRequested: request.model, latencyMS: latencyMS, contentType: contentType)
    }

    // MARK: - Response parsing

    /// Sniffs the payload rather than trusting `Content-Type`, because a
    /// proxy can rewrite the header: an SSE body begins with `data:` once
    /// leading whitespace is stripped.
    static func parseBody(_ data: Data,
                          modelRequested: String,
                          latencyMS: Int,
                          contentType: String? = nil) throws -> AIResponse {
        let head = data.prefix(64).drop(while: { $0 == 0x20 || $0 == 0x0a || $0 == 0x0d || $0 == 0x09 })
        let isSSE = head.starts(with: Array("data:".utf8))
            || (contentType?.contains("text/event-stream") ?? false)
        if isSSE {
            // AIRequest.stream is hard-coded false, so a server that answers
            // SSE anyway is misbehaving (spec §0/§2.2 "the SSE trap"). Rather
            // than reassemble a stream that was never asked for, this reader
            // sniffs and rejects: a truncated/garbled reassembly is a worse
            // failure mode than a clean hop to the next candidate.
            throw AIError.badJSON(prefix: String(decoding: data.prefix(200), as: UTF8.self))
        }
        return try parseJSON(data, modelRequested: modelRequested, latencyMS: latencyMS)
    }

    private struct Envelope: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }   // reasoning_content NOT decoded
            let message: Message?
            let finish_reason: String?
        }
        struct Usage: Decodable {
            struct Details: Decodable { let reasoning_tokens: Int? }
            let prompt_tokens: Int?
            let completion_tokens: Int?
            let completion_tokens_details: Details?
        }
        let model: String?
        let choices: [Choice]
        let usage: Usage?
    }

    static func parseJSON(_ data: Data, modelRequested: String, latencyMS: Int) throws -> AIResponse {
        let env: Envelope
        do { env = try JSONDecoder().decode(Envelope.self, from: data) }
        catch { throw AIError.badJSON(prefix: String(decoding: data.prefix(200), as: UTF8.self)) }
        guard let choice = env.choices.first else {
            throw AIError.badJSON(prefix: "empty choices")
        }
        let content = choice.message?.content ?? ""
        guard !content.isEmpty else { throw AIError.badJSON(prefix: "empty completion") }
        return AIResponse(content: content,
                          finishReason: FinishReason(wire: choice.finish_reason),
                          modelRequested: modelRequested,
                          modelServed: env.model,
                          promptTokens: env.usage?.prompt_tokens,
                          completionTokens: env.usage?.completion_tokens,
                          reasoningTokens: env.usage?.completion_tokens_details?.reasoning_tokens,
                          latencyMS: latencyMS)
    }

}
