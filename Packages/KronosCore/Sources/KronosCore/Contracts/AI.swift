// Part of the frozen contract surface. See Contracts.swift.
//
// The AI transport contract: what a provider client is, what one request and
// one reply look like on the wire, and how a failure is classified.
//
// Two rules from SPEC §3 are load-bearing here and are enforced by tests:
//  * `AIRequest.stream` is a NON-optional Bool hard-coded to false. Swift's
//    JSONEncoder omits a nil `Bool?`, and omitting the key makes the gateway
//    answer `text/event-stream`, which crashes JSONDecoder (SPEC §12.0).
//  * `finishReason == .length` is a FAILURE, not a success (ai-2). A truncated
//    reply is an immediate hop to the next candidate, never a retry on the
//    same model, which would truncate identically.

import Foundation

// MARK: - Data policy

/// What the provider's terms permit it to do with the text Kronos sends.
/// Resolved by longest-prefix match against the bundled model catalog;
/// `*` is the terminal fallback, so an unclassified endpoint is `.unknown`.
public enum DataPolicy: String, Codable, CaseIterable, Sendable {
    /// Contractually not trained on, deleted within 30 days.
    case zeroRetention
    /// Provider terms permit training and/or human review.
    case mayTrain
    /// Unclassified endpoint (user-supplied base URL, third-party gateway).
    case unknown
    /// Nothing leaves the Mac at all — the on-device Apple Intelligence
    /// client's policy, strictly stronger than `.zeroRetention` (which
    /// still crosses the network to a provider that promises not to keep it).
    case onDevice
}

/// The privacy gate. `.off` is a fully supported
/// operating mode, not a degraded one: every feature keeps a deterministic
/// path and the app never touches the network in `.off`.
///
/// `.privateOnly`: `AIRouter` filters candidates to `dataPolicy == .onDevice
/// || .zeroRetention` before walking the chain — see
/// `AIRouter.eligibleCandidates`. `.off` still short-circuits before any
/// candidate, filtered or not, is ever touched (`aiModeOffStillNeverTouchesAnyClient`).
public enum AIMode: String, Codable, CaseIterable, Sendable {
    case off
    case privateOnly
    case allowAny
}

/// Which prompt a request renders. Selects the schema, the token budget and
/// the wall-clock budget (see `AIBudget`).
public enum PromptKind: String, Codable, CaseIterable, Sendable {
    case triage
    case retriage
    case impulsPick
    case ordoResort
    case breakdown
    /// Extracting tasks from a pasted note dump.
    case extract
}

// MARK: - Budgets

/// Per-call budgets. Expressed in seconds and tokens so the values are
/// comparable to measured latencies without unit games.
public enum AIBudget {
    /// Total wall-clock budget for one call, in seconds.
    ///
    /// `impulsPick` is the hard one: Impuls renders a deterministic card in
    /// ≤100 ms and the AI may only crossfade the mentor line inside a 4 s
    /// window. On timeout the request is dropped silently — no spinner, no
    /// error toast, and the displayed task never changes.
    public static func seconds(for kind: PromptKind) -> Double {
        switch kind {
        case .impulsPick:                  return 4
        // 45 s: a free reasoning model answers in ~6 s at the median but spikes to ~40 s.
        case .triage, .retriage, .breakdown: return 45
        case .ordoResort:                  return 25
        // 45 s: raised from 25 s after measuring the SAME shape triage already got 45 s for —
        // median 10.5 s, worst 21.2 s, one 81 s outlier — with a big-note-dump paste sitting
        // right at the old 25 s edge and timing out on some runs. Unlike a bare 25 s timeout
        // costing the AI result outright, a longer wait costs the user nothing VISIBLE: the
        // deterministic split is already on screen the instant they paste
        // (`CaptureModel.findTasks()` runs `NoteSplitter.split` synchronously before ever
        // calling AI). `CaptureReviewList.askingText` shows a STATIC "Asking <model>…" (no live
        // elapsed-seconds counter) for as long as `isUpgrading` is true — identical text at
        // second 25 and second 45, never frozen/stale-looking because SwiftUI keeps the view
        // alive and responsive the whole time, but also not literally counting.
        case .extract:                     return 45
        }
    }

    /// `max_tokens` for one call. Never 400: a reply of `{"ok":true}` was
    /// measured burning 209–269 reasoning tokens (SPEC §12.1), so a 400-token
    /// ceiling cannot survive a real prompt.
    public static func maxTokens(for kind: PromptKind) -> Int {
        switch kind {
        case .ordoResort: return 4000
        case .extract:    return 4000
        default:          return 2500
        }
    }

    /// Connect timeout, in seconds, for every call.
    public static let connectSeconds: Double = 3
}

// MARK: - AIRequest

/// One OpenAI-compatible chat completion request.
///
/// `Encodable` conformance IS the wire format: this type encodes directly to
/// the request body, so the coding keys are snake_case where the API is.
/// Encode-only on purpose — Kronos never receives a request, and `kind` and
/// `budgetSeconds` are local routing metadata that has no place on the wire.
public struct AIRequest: Encodable, Equatable, Sendable {

    /// One chat message. `role` is "system" | "user" | "assistant".
    public struct Message: Codable, Equatable, Sendable {
        public let role: String
        public let content: String

        public init(role: String, content: String) {
            self.role = role
            self.content = content
        }

        public static func system(_ content: String) -> Message { Message(role: "system", content: content) }
        public static func user(_ content: String)   -> Message { Message(role: "user", content: content) }
    }

    public let model: String
    public let messages: [Message]
    public let maxTokens: Int
    public let temperature: Double

    /// Hard-coded `false`, non-optional, always encoded.
    ///
    /// This is not a preference. A `Bool?` left nil is omitted by JSONEncoder,
    /// and an omitted key makes the gateway answer `text/event-stream`, which
    /// crashes JSONDecoder. Measured 2026-09-16: key omitted → SSE; `false` →
    /// `application/json`, even with `Accept: text/event-stream`. The reader
    /// still sniffs for a `data:` prefix as the second half of the mitigation.
    /// `ContractTests.streamIsAlwaysEncodedFalse` asserts the encoded body
    /// literally contains `"stream":false`.
    public let stream: Bool

    /// OpenRouter-only: `{"reasoning":{"enabled":false}}`. Measured on a free reasoning model
    /// (nemotron-3-ultra free): with reasoning on, median 35 s and one empty answer in 6
    /// (the 25 s triage budget expired on most calls = "AI never loads"); with it off 6/6 valid
    /// answers with all four fields, median 5.7 s. Encoded only when set (nil for other gateways,
    /// which may reject unknown keys).
    public var reasoning: ReasoningControl?

    public struct ReasoningControl: Codable, Equatable, Sendable {
        public let enabled: Bool
        public init(enabled: Bool) { self.enabled = enabled }
    }

    // Not part of the wire body: local routing metadata.
    /// Which prompt this request renders; drives budget and validation.
    public let kind: PromptKind
    /// Total wall-clock budget for this request, in seconds.
    public let budgetSeconds: Double

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, stream, reasoning
        case maxTokens = "max_tokens"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(model, forKey: .model)
        try c.encode(messages, forKey: .messages)
        try c.encode(maxTokens, forKey: .maxTokens)
        try c.encode(temperature, forKey: .temperature)
        try c.encode(stream, forKey: .stream)
        try c.encodeIfPresent(reasoning, forKey: .reasoning)
    }

    public init(model: String,
                messages: [Message],
                kind: PromptKind,
                maxTokens: Int? = nil,
                temperature: Double = 0,
                budgetSeconds: Double? = nil) {
        self.model         = model
        self.messages      = messages
        self.kind          = kind
        self.maxTokens     = maxTokens ?? AIBudget.maxTokens(for: kind)
        self.temperature   = temperature
        self.budgetSeconds = budgetSeconds ?? AIBudget.seconds(for: kind)
        self.stream        = false
    }

    /// The exact bytes sent as the HTTP body. Keys are sorted so the body is
    /// byte-stable across runs, which is what makes the `"stream":false`
    /// assertion a real test rather than a dictionary-order coin flip.
    public func encodedBody() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(self)
    }
}

// MARK: - AIResponse

/// Why the model stopped. `.length` is the one that matters: it means the
/// reply is cut off mid-JSON and must be treated as a failure (ai-2).
public enum FinishReason: String, Codable, CaseIterable, Sendable {
    case stop
    case length
    case toolUse   = "tool_use"
    case contentFilter = "content_filter"
    case other

    /// Tolerant decode: an unrecognised provider string becomes `.other`
    /// rather than throwing, because a new finish reason is not a crash.
    public init(wire: String?) {
        switch wire {
        case "stop", "end_turn":             self = .stop
        case "length", "max_tokens":         self = .length
        case "tool_use", "tool_calls":       self = .toolUse
        case "content_filter":               self = .contentFilter
        default:                             self = .other
        }
    }
}

/// One decoded chat completion. `content` is the assistant text ONLY —
/// `reasoning_content` is discarded before this type is built, so no prompt
/// ever sees a model's scratch work.
public struct AIResponse: Codable, Equatable, Sendable {
    public let content: String
    public let finishReason: FinishReason
    public let modelRequested: String
    public let modelServed: String?
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let reasoningTokens: Int?
    public let latencyMS: Int

    public init(content: String,
                finishReason: FinishReason,
                modelRequested: String,
                modelServed: String? = nil,
                promptTokens: Int? = nil,
                completionTokens: Int? = nil,
                reasoningTokens: Int? = nil,
                latencyMS: Int = 0) {
        self.content          = content
        self.finishReason     = finishReason
        self.modelRequested   = modelRequested
        self.modelServed      = modelServed
        self.promptTokens     = promptTokens
        self.completionTokens = completionTokens
        self.reasoningTokens  = reasoningTokens
        self.latencyMS        = latencyMS
    }

    /// The `finish_reason` gate.
    ///
    /// A reply that stopped on `.length` is truncated JSON: it is a provider
    /// failure, never a success with a short answer. Callers run this BEFORE
    /// attempting to decode `content`.
    ///
    /// - Returns: the response itself when usable.
    /// - Throws: `AIError.truncated` when `finishReason == .length`.
    @discardableResult
    public func validated() throws -> AIResponse {
        if finishReason == .length {
            throw AIError.truncated(reasoningTokens: reasoningTokens)
        }
        return self
    }
}

// MARK: - AIError

/// Every way an AI call fails, classified for the router.
///
/// Deliberately smaller than a full provider-error taxonomy:
/// the five cases below are the ones a caller must branch on. Provider detail
/// (status body, retry-after) rides along as an associated value rather than
/// as its own case, because no caller branches differently on it.
public enum AIError: Error, Equatable, Sendable {
    /// Wall-clock budget exhausted. For `impulsPick` this is the normal,
    /// silent outcome — the deterministic card is already on screen.
    case timeout(budgetSeconds: Double)
    /// `finish_reason == "length"`. Hop to the next candidate; never retry
    /// the same model, which would truncate identically.
    case truncated(reasoningTokens: Int?)
    /// A 200 that did not yield the prompt's schema: unparseable, empty, or
    /// parsed-but-invalid. Carries at most 200 chars for the log, never shown.
    case badJSON(prefix: String)
    /// Transport or provider status failure. 401/403 marks the provider
    /// unusable; 400 marks the model dead for 6 h; 5xx and 429 back off.
    case http(Int)
    /// Routing found nothing eligible: no key, `AIMode.off`, policy gate, or
    /// every candidate exhausted. Straight to the deterministic path.
    case noUsableProvider

    /// True when the router should immediately try the next candidate rather
    /// than giving up or retrying the same model.
    public var shouldHop: Bool {
        switch self {
        case .truncated, .badJSON, .timeout: return true
        case .http(let status):              return status != 401 && status != 403
        case .noUsableProvider:              return false
        }
    }
}

extension AIError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .timeout(let b):        return "timeout after \(b)s"
        case .truncated(let r):      return "truncated (reasoning tokens: \(r.map(String.init) ?? "unknown"))"
        case .badJSON(let p):        return "badJSON: \(p.prefix(200))"
        case .http(let s):           return "http \(s)"
        case .noUsableProvider:      return "no usable provider"
        }
    }
}

// MARK: - AIClient

/// One configured provider endpoint. Implementations are `Sendable` value
/// types and MUST honour task cancellation: cancelling the parent Task
/// cancels the HTTP request. Impuls depends on that (4 s crossfade window).
public protocol AIClient: Sendable {
    /// The model this client sends to, e.g. `claude-sonnet-5`.
    var modelID: String { get }
    /// Resolved from the bundled catalog by longest-prefix match.
    var dataPolicy: DataPolicy { get }

    /// Send one request and return the decoded reply.
    ///
    /// Implementations throw `AIError` and nothing else. They do NOT apply
    /// the `finish_reason` gate — call `AIResponse.validated()` for that, so
    /// the truncation rule lives in exactly one place.
    func send(_ request: AIRequest) async throws -> AIResponse
}

// MARK: - AIRouting

/// The feature-level AI surface. Everything above the transport calls this,
/// never `AIClient` directly, so the fallback chain and the deterministic
/// path are impossible to bypass.
///
/// Every method returns a usable value or throws `AIError`. A caller that
/// catches an error uses its deterministic fallback; none of these methods is
/// allowed to leave a feature with nothing to render.
public protocol AIRouting: Sendable {
    /// Classify one new task. Budget 25 s, background queue, nobody waits.
    ///
    /// Deterministic fallback: quick-add parser output only (`depth`
    /// `.unknown`, no estimate, no energy kind), `firstMove` from the §6.2
    /// template, and `TriageResult.version == 0` so the queue re-triages the
    /// row automatically once a provider returns.
    ///
    /// Triage writes only fields still unset; `lockedFields` names what the
    /// user or `create_task` set explicitly and must not be overwritten.
    ///
    /// `context`: up to 8 similar tasks already in the list, built by
    /// `TriageContextBuilder.build`. Rendered into the prompt as worked
    /// examples when AI answers, and consumed directly by `NeighbourTriage`
    /// as the deterministic fallback when it does not. Defaults to `.empty`
    /// so every rev 1-6 call site (none pass it yet) keeps compiling.
    func triage(title: String,
                notes: String,
                projectNames: [String],
                labelNames: [String],
                today: Int,
                lockedFields: Set<String>,
                context: TriageContext) async throws -> TriageResult

    /// Re-classify after the user said the last result was wrong. Budget 25 s.
    /// The correction outranks both the model's judgement and the house rules.
    /// May return at most one `ProposedRule`, which is shown only after the
    /// no-op guard and the dedupe check, and saved only on an explicit tap.
    ///
    /// Deterministic fallback: the previous result, unchanged, with no rule.
    func retriage(title: String,
                  notes: String,
                  previous: TriageResult,
                  feedback: String,
                  projectNames: [String],
                  labelNames: [String],
                  today: Int) async throws -> TriageResult

    /// Re-rank already-filtered Impuls candidates and write one mentor line
    /// each. Budget 4 s HARD.
    ///
    /// This may NEVER swap the displayed task: the deterministic card is
    /// already on screen within 100 ms and only the mentor line crossfades in.
    /// On timeout the request is dropped silently.
    ///
    /// Deterministic fallback: the ranking order as given, with a mentor line
    /// drawn from the bundled pool keyed by energy level.
    func impulsPick(candidates: [Candidate],
                    energy: KEnergyLevel,
                    language: String) async throws -> ImpulsRanking

    /// RESERVED, NO UI IN ALPHA (rev 3). ORDO became automatic — the menu bar
    /// shows the first row of the open list under its own filter and sort, so
    /// there is no hand-curated queue for a chat command to reorder. The
    /// declaration stays so the shape is settled if the surface returns; no
    /// alpha caller invokes it.
    ///
    /// Reorder the ORDO queue from a natural-language instruction.
    /// Budget 25 s, 4000 max tokens; the user sees an inline progress row.
    ///
    /// The returned `order` must be an exact permutation of `1...N` — a reply
    /// that adds, drops or duplicates a position is rejected whole and the
    /// queue is left untouched.
    ///
    /// Deterministic fallback: the grammar path handles the common commands
    /// with no AI call at all; on failure the queue is unchanged and the
    /// explanation is "Not a queue instruction".
    func ordoResort(queueTitles: [String],
                    message: String,
                    history: [String],
                    language: String) async throws -> OrdoResort

    /// Extract tasks from a pasted note dump.
    /// Budget 25 s, background — nobody waits on a spinner.
    ///
    /// The deterministic result (`NoteSplitter.split`) is computed FIRST and
    /// returned immediately when `AIMode == .off`, without touching the
    /// network. When AI is enabled, its reply improves on that result but
    /// every task it proposes must carry a `sourceLine` that exists verbatim
    /// (folded, trimmed) in `text`; a task that fails this check is dropped
    /// and counted, never invented into the store.
    ///
    /// Deterministic fallback: `NoteSplitter.split(text, ...)`,
    /// `ExtractResult.isDeterministic == true`.
    func extractTasks(from text: String,
                      projectNames: [String],
                      existingOpenTitles: [String],
                      today: Int) async -> ExtractResult

    /// Split one task into 3-7 concrete subtasks.
    /// Budget 25 s.
    ///
    /// The deterministic result (`DeterministicBreakdown.steps`) is computed
    /// first; AI may only improve it, and its reply is accepted only when it
    /// yields 3-7 non-empty steps, none equal (folded) to a step already in
    /// `existingSubtasks` — this never touches or reorders existing subtasks.
    ///
    /// Deterministic fallback: `DeterministicBreakdown.steps(title:notes:language:)`,
    /// `BreakdownResult.isDeterministic == true`.
    func breakdown(title: String,
                  notes: String,
                  existingSubtasks: [String]) async -> BreakdownResult
}
