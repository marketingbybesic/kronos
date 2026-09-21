// Builds `AppModel.ai` from the Settings > AI preferences. nil = AI off: every AI feature then
// takes its deterministic path and nothing touches the network.
import Foundation
import KronosCore

@MainActor
enum AIWiring {
    /// The model tried after the chosen one, WITHIN THE SAME PROVIDER (INTEGRATION.md:
    /// sonnet -> astra -> deterministic). The fallback id is provider-specific because a
    /// candidate must hit the same gateway with the same key service as the one it backs up;
    /// only GhostCLI has a same-provider fallback today. OpenRouter's three free models are
    /// already tried as distinct candidates by the caller below via `provider.models`, so it
    /// needs no separate fallback id.
    private static func fallbackModel(for provider: AIProvider) -> String? {
        provider == .ghostCLI ? "gpt-6-astra" : nil
    }

    static func configure(_ model: AppModel) {
        // Self-test: only the on-device model (no API key, no Keychain, no network).
        if LiveSelfTest.reportPath != nil {
            model.ai = AppleIntelligenceClientFactory.make().map {
                AIRouter(mode: .privateOnly, candidates: [AIRoutedCandidate(client: $0)])
            }
            return
        }
        let mode = AppSettingsStore.aiMode
        guard mode != .off, let base = URL(string: AppSettingsStore.aiBaseURL) else {
            model.ai = nil
            return
        }
        let provider = AppSettingsStore.aiProvider
        var ids = [AppSettingsStore.aiModel]
        if let fallback = fallbackModel(for: provider), !ids.contains(fallback) {
            ids.append(fallback)
        }
        var candidates = ids.map {
            AIRoutedCandidate(client: GhostCLIClient(modelID: $0, baseURL: base,
                                                      keyService: provider.keychainService,
                                                      extraHeaders: provider.extraHeaders))
        }
        // Insurance: the on-device Apple model is the last hop before the deterministic path. Nothing
        // leaves the Mac, so the router also keeps it in private-only mode (it filters by data policy).
        if let apple = AppleIntelligenceClientFactory.make() {
            candidates.append(AIRoutedCandidate(client: apple))
        }
        model.ai = AIRouter(mode: mode, candidates: candidates)
    }

    /// Settings writes plain UserDefaults; rebuild the router whenever they change.
    static func observe(_ model: AppModel) {
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { configure(model) }
        }
    }
}
