// The on-device Apple Intelligence client: the LAST candidate in the
// fallback chain, usable even in `AIMode.privateOnly` because nothing it
// sends leaves the Mac. Everything that touches `FoundationModels` sits
// behind `#if canImport(FoundationModels)` + `@available(macOS 26.0, *)` so
// the package keeps compiling — and this file keeps compiling — on macOS 14,
// which is the deployment target.
//
// FoundationModels API read from this machine's SDK (not guessed):
// `$(xcrun --show-sdk-path)/System/Library/Frameworks/FoundationModels.framework`
// — `SystemLanguageModel.default.availability` is `.available` or
// `.unavailable(UnavailableReason)` with reasons `.deviceNotEligible`,
// `.appleIntelligenceNotEnabled`, `.modelNotReady`; `LanguageModelSession`
// takes a `String?` instructions overload and `respond(to: String) async
// throws -> Response<String>` whose `.content` is the plain reply text —
// the same "system + user text in, JSON text out" shape every other
// `AIClient` already implements, so the shared validators decode it as-is.

import Foundation

/// Human-readable availability, usable from macOS 14 code (Settings shows
/// this even when the framework itself cannot be imported at the call site,
/// e.g. a non-macOS-26 build machine — which never happens for the app's own
/// minimum OS but keeps this type usable everywhere `AIClient` is).
public enum AppleIntelligenceAvailability: Equatable, Sendable {
    case available
    /// Apple Intelligence is off in System Settings.
    case notEnabled
    /// This Mac cannot run the on-device model at all.
    case notEligible
    /// Eligible and enabled, but the model has not finished downloading/warming.
    case modelNotReady
    /// This OS predates FoundationModels (below macOS 26), or the framework
    /// was unavailable at compile time.
    case osTooOld

    /// One short, calm line for Settings — never an error tone: no alarm language for
    /// something the user cannot fix from inside Kronos.
    public var statusLine: String {
        switch self {
        case .available:    return "Apple Intelligence is available on this Mac."
        case .notEnabled:   return "Turn on Apple Intelligence in System Settings to use it here."
        case .notEligible:  return "This Mac cannot run Apple Intelligence."
        case .modelNotReady: return "Apple Intelligence is still preparing on this Mac."
        case .osTooOld:     return "Apple Intelligence needs a newer version of macOS."
        }
    }
}

/// Namespace for the availability check + factory, kept usable from
/// macOS-14-targeted call sites (Settings, `AIWiring`) without an
/// `#if canImport` at every use site — only this file's internals need it.
public enum AppleIntelligence {
    /// Current availability. Always returns a value; never throws.
    public static var isAvailable: Bool { availability == .available }

    public static var availability: AppleIntelligenceAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .available
            case .unavailable(.deviceNotEligible): return .notEligible
            case .unavailable(.appleIntelligenceNotEnabled): return .notEnabled
            case .unavailable(.modelNotReady): return .modelNotReady
            case .unavailable: return .modelNotReady
            }
        }
        return .osTooOld
        #else
        return .osTooOld
        #endif
    }
}

#if canImport(FoundationModels)
import FoundationModels

/// Wraps `SystemLanguageModel`/`LanguageModelSession` behind the exact same
/// `AIClient` shape `GhostCLIClient` implements, so `AIRouter`'s fallback
/// chain, validators and drift guards apply unchanged.
///
/// `availability` is an injectable closure — never the live
/// `SystemLanguageModel` — so every test in this package runs without the
/// real framework and without needing Apple Intelligence turned on on the
/// build machine (spec requirement: `appleClientSkippedWhenUnavailable`).
@available(macOS 26.0, *)
public struct AppleIntelligenceClient: AIClient {
    public let modelID = "apple-on-device"
    /// Nothing sent to this client ever leaves the Mac, so it stays usable
    /// even in `AIMode.privateOnly`.
    public let dataPolicy: DataPolicy = .onDevice

    private let availability: @Sendable () -> AppleIntelligenceAvailability
    private let makeSession: @Sendable (String) -> LanguageModelSession

    /// - Parameters:
    ///   - availability: checked before every `send`; defaults to the live
    ///     system check. Tests inject a constant closure instead.
    ///   - makeSession: builds the session for one request's system prompt.
    ///     Defaults to a real `LanguageModelSession(model:instructions:)`;
    ///     tests never need to override this because they short-circuit on
    ///     `availability` first — it exists purely so a live test can swap
    ///     in a session against a non-default model if ever needed.
    public init(availability: @escaping @Sendable () -> AppleIntelligenceAvailability = { AppleIntelligence.availability },
                makeSession: (@Sendable (String) -> LanguageModelSession)? = nil) {
        self.availability = availability
        self.makeSession = makeSession ?? { instructions in
            LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
        }
    }

    public func send(_ request: AIRequest) async throws -> AIResponse {
        guard availability() == .available else { throw AIError.noUsableProvider }

        let system = request.messages.first { $0.role == "system" }?.content ?? ""
        let user = request.messages.first { $0.role == "user" }?.content ?? ""
        let session = makeSession(system)

        let start = Date()
        do {
            try await Task.sleep(for: .seconds(0))   // yield point so cancellation is observed before the call
            try Task.checkCancellation()
            let response = try await session.respond(to: user)
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            return AIResponse(content: response.content, finishReason: .stop,
                              modelRequested: request.model, modelServed: modelID,
                              latencyMS: latency)
        } catch is CancellationError {
            throw AIError.timeout(budgetSeconds: request.budgetSeconds)
        } catch {
            // FoundationModels' own error taxonomy (guardrail violation,
            // unsupported language, context window) has no analogue in
            // `AIError`; `badJSON` is the closest existing case that still
            // makes the router hop to the next candidate rather than give up
            // (`shouldHop` is true for `.badJSON`), which is the behaviour
            // every other transport failure here already gets.
            throw AIError.badJSON(prefix: String(describing: error).prefix(200).description)
        }
    }
}

/// Builds the client only when this Mac can actually use it, so the app
/// target never has to sprinkle `#if canImport(FoundationModels)` at its own
/// wiring call site — this factory exists on macOS 14 code too, always
/// returning `nil` there.
public enum AppleIntelligenceClientFactory {
    /// `nil` when the OS predates FoundationModels. Availability at the
    /// moment of a `send` call (not at construction time) is what actually
    /// gates use — the app may build this once at launch and Apple
    /// Intelligence may become available/unavailable later in the session;
    /// `AppleIntelligenceClient.send` re-checks every call.
    @MainActor
    public static func make() -> (any AIClient)? {
        if #available(macOS 26.0, *) {
            return AppleIntelligenceClient()
        }
        return nil
    }
}
#else

/// macOS-14-buildable stand-in so `AppleIntelligenceClientFactory.make()` is
/// callable from every build configuration; always `nil` because the
/// framework was unavailable at compile time.
public enum AppleIntelligenceClientFactory {
    @MainActor
    public static func make() -> (any AIClient)? { nil }
}
#endif
