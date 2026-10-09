// Builds `AppModel.ai` from the Settings > AI preferences and the active house rules. nil = AI off:
// every AI feature then takes its deterministic path and nothing touches the network.
//
// Preferences are read from `KronosEnv.defaults` (through `AppSettingsStore`), so a live test or a
// snapshot run never reads or writes the person's own defaults domain.
import Foundation
import Observation
import KronosCore

@MainActor
enum AIWiring {
    /// How many times a router was built. A change to an unrelated preference must not move it.
    private(set) static var rebuildCount = 0
    private static var lastSignature: RouterConfigSignature?
    private static var defaultsObserver: NSObjectProtocol?

    /// The model tried after the chosen one, WITHIN THE SAME PROVIDER (INTEGRATION.md:
    /// sonnet -> astra -> deterministic). The fallback id is provider-specific because a
    /// candidate must hit the same gateway with the same key service as the one it backs up;
    /// only GhostCLI has a same-provider fallback today. OpenRouter's three free models are
    /// already tried as distinct candidates by the caller below via `provider.models`, so it
    /// needs no separate fallback id.
    private static func fallbackModel(for provider: AIProvider) -> String? {
        #if KRONOS_PUBLIC
        return nil
        #else
        return provider == .ghostCLI ? "gpt-6-astra" : nil
        #endif
    }

    /// Everything a built router depends on. Equal signatures mean the router in place is right.
    static func signature(for model: AppModel) -> RouterConfigSignature {
        RouterConfigSignature(mode: AppSettingsStore.aiMode,
                              provider: AppSettingsStore.aiProvider.rawValue,
                              baseURL: AppSettingsStore.aiBaseURL,
                              modelID: AppSettingsStore.aiModel,
                              rules: model.store.activeHouseRules())
    }

    /// Builds the http-gateway candidate chain (model + fallback model, if any) for a
    /// non-subprocess provider. `nil` when `signature.baseURL` is not a valid URL — the
    /// caller treats that as "no router at all", matching the pre-B1 behaviour exactly.
    private static func httpCandidates(signature: RouterConfigSignature, provider: AIProvider) -> [AIRoutedCandidate]? {
        guard let base = URL(string: signature.baseURL) else { return nil }
        var ids = [signature.modelID]
        if let fallback = fallbackModel(for: provider), !ids.contains(fallback) {
            ids.append(fallback)
        }
        return ids.map {
            AIRoutedCandidate(client: OpenAICompatibleClient(modelID: $0, baseURL: base,
                                                             keyService: provider.keychainService,
                                                             extraHeaders: provider.extraHeaders))
        }
    }

    /// Builds the router unconditionally (launch). Later changes go through `refresh`.
    static func configure(_ model: AppModel) {
        rebuildCount += 1
        // Self-test: only the on-device model (no API key, no Keychain, no network).
        if LiveSelfTest.reportPath != nil {
            model.ai = AppleIntelligenceClientFactory.make().map {
                AIRouter(mode: .privateOnly, candidates: [AIRoutedCandidate(client: $0)])
            }
            return
        }
        let signature = signature(for: model)
        lastSignature = signature
        guard signature.mode != .off else {
            model.ai = nil
            return
        }
        let provider = AppSettingsStore.aiProvider
        var candidates: [AIRoutedCandidate]
        // Readiness point 1: the old `guard let base = URL(...)` gate excluded every provider
        // from building ANY router when the URL failed to parse — including a key-less,
        // URL-less subprocess provider that never had a URL to parse in the first place.
        // `.claudeCode` now reaches its candidate directly; every other provider still goes
        // through the exact same URL-or-nil-router gate as before.
        #if !KRONOS_PUBLIC
        if provider == .claudeCode {
            candidates = [AIRoutedCandidate(client: ClaudeCodeClient(modelID: signature.modelID))]
        } else {
            guard let http = httpCandidates(signature: signature, provider: provider) else {
                model.ai = nil
                return
            }
            candidates = http
        }
        #else
        guard let http = httpCandidates(signature: signature, provider: provider) else {
            model.ai = nil
            return
        }
        candidates = http
        #endif
        // Insurance: the on-device Apple model is the last hop before the deterministic path. Nothing
        // leaves the Mac, so the router also keeps it in private-only mode (it filters by data policy).
        if let apple = AppleIntelligenceClientFactory.make() {
            candidates.append(AIRoutedCandidate(client: apple))
        }
        model.ai = AIRouter(mode: signature.mode, candidates: candidates, houseRules: signature.rules)
    }

    /// Rebuilds the router only when the mode, provider, URL, model or an active rule changed.
    static func refresh(_ model: AppModel) {
        guard signature(for: model) != lastSignature else { return }
        configure(model)
    }

    /// Settings write plain defaults and rules change with store edits (this app or an agent):
    /// both are watched, and both only rebuild the router when the signature moved.
    static func observe(_ model: AppModel) {
        stopObserving()
        observing = true
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                                  object: KronosEnv.defaults, queue: .main) { _ in
            MainActor.assumeIsolated { refresh(model) }
        }
        trackStore(model)
    }

    /// Ends both watches (the live test starts its own and takes it down again).
    static func stopObserving() {
        observing = false
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        defaultsObserver = nil
    }

    private static var observing = false

    private static func trackStore(_ model: AppModel) {
        guard observing else { return }
        withObservationTracking {
            _ = model.version
        } onChange: {
            Task { @MainActor in
                guard observing else { return }
                refresh(model)
                trackStore(model)
            }
        }
    }
}
