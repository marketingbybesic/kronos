// Kronos/Settings/AISettingsController.swift
// Keychain + Test logic for Settings -> AI, kept out of the view so SettingsAITab stays
// thin and so snapshot mode never touches the network or the real Keychain (fakes are
// injected under KRONOS_SNAPSHOT). A changed model/URL/key cannot be
// saved until a Test against THAT configuration has passed.

import Foundation
import KronosCore

/// A provider bundles the base URL, its model list, and which Keychain entry its key lives
/// under, so switching providers can never leave the app pointed at one provider's URL with
/// another's key or model (the bug a single free-text URL field invited). `.custom` is the
/// escape hatch for anything not listed.
///
/// Model ids and base URLs were measured live: GhostCLI answers claude-opus-5 in 13s,
/// claude-sonnet-5 in 17s, gpt-6-astra in 5s; OpenRouter's free models answer in ~1s.
/// opencode-go is deliberately NOT a case here — its endpoint only serves the opencode
/// client, never Kronos.
enum AIProvider: String, CaseIterable, Identifiable {
    #if !KRONOS_PUBLIC
    case ghostCLI
    case claudeCode
    #endif
    case openRouter
    case custom

    var id: String { rawValue }

    /// The providers the picker lists by name. `.custom` is not one of them: the picker ends with
    /// "Other…", which is where a gateway of your own goes.
    static var presets: [AIProvider] { allCases.filter { $0 != .custom } }

    var defaultBaseURL: String {
        switch self {
        #if !KRONOS_PUBLIC
        case .ghostCLI:   return "https://ghostcli.dev/v1"
        case .claudeCode: return ""   // subprocess, not a gateway
        #endif
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .custom:     return ""
        }
    }

    /// Fixed model choices offered in the picker. Empty for `.custom`, where the model
    /// field is free text only.
    var models: [String] {
        switch self {
        #if !KRONOS_PUBLIC
        case .ghostCLI:   return ["claude-opus-5", "claude-sonnet-5", "claude-fable-5.1", "gpt-6-astra"]
        // Measured live 2026-10-09 via `claude -p --model <id> --output-format json`: this
        // machine's org has subscription CLI access disabled (api_error_code
        // "oauth_not_allowed_for_organization"), identically for claude-sonnet-5 and
        // claude-haiku-4-5 — a policy block, not a per-model rejection, so model validity
        // itself could not be confirmed live here. Falls back to the plan's own
        // known-valid list (claude-sonnet-5, claude-fable-5-1) rather than guessing.
        case .claudeCode: return ["claude-sonnet-5", "claude-fable-5-1"]
        #endif
        case .openRouter: return ["qwen/qwen3.8-27b:free", "nvidia/nemotron-3-ultra-550b-a55b:free", "nex-agi/nex-n2.5-pro:free"]
        case .custom:     return []
        }
    }

    /// Logical name of this provider's key inside the app-owned secret store
    /// (`KeychainSecretStore`, service `com.besic.kronos.secret`). `GhostCLIClient`'s
    /// `keyProvider` reads this through `KeychainKeyProvider`, which now resolves it against
    /// the app-owned store, not a raw Keychain service string — an item under this name was
    /// created by this running app, so later launches read it with no Keychain dialog. Kept
    /// as `keychainService` (not renamed) because `Kronos/App/AIWiring.swift` (a different
    /// leaf's file) already reads this property by that name to build the live AI client.
    ///
    /// `.claudeCode` never reads a Keychain entry: the CLI holds its own OAuth session, so
    /// this resolves to `""` and `AISettingsController` never calls `store.read`/`write` for it.
    var keychainService: String {
        switch self {
        #if !KRONOS_PUBLIC
        case .ghostCLI:   return GhostCLIClient.keychainService   // "ai.ghostcli"
        case .claudeCode: return ""
        #endif
        case .openRouter: return "ai.openrouter"
        case .custom:     return "ai.custom"
        }
    }

    /// The legacy Keychain service this provider's key lived under before the app-owned
    /// secret store existed. Never written to by this app any more — read-only, and only
    /// from the explicit "use the key already in your Keychain" adopt action — because
    /// `scripts/triage-eval.mjs` and `scripts/capture-eval.mjs` read `OPENROUTER_API_KEY`
    /// directly via the `security` CLI and must keep working regardless of what the app does.
    var legacyKeychainService: String {
        switch self {
        #if !KRONOS_PUBLIC
        case .ghostCLI:   return GhostCLIClient.legacyKeychainService
        case .claudeCode: return ""   // no key, nothing to adopt
        #endif
        case .openRouter: return "OPENROUTER_API_KEY"
        case .custom:     return "kronos.ai.custom_key"
        }
    }

    /// The legacy items were written with `kSecAttrService` only, no `kSecAttrAccount` — the
    /// account for `readLegacy` must be nil, not "", to match the exact query that finds them.
    var legacyKeychainAccount: String? { nil }

    /// The CLI binary path shown (read-only) in Settings for `.claudeCode`; `nil` for every
    /// other provider, which the view reads to decide whether to show it at all.
    var executablePath: String? {
        #if !KRONOS_PUBLIC
        self == .claudeCode ? "/opt/homebrew/bin/claude" : nil
        #else
        nil
        #endif
    }

    /// True for a provider that talks to a local subprocess instead of an HTTP gateway —
    /// `SettingsAITab` reads this once to hide the URL/key controls and show `executablePath`
    /// instead, so the view never needs its own `#if !KRONOS_PUBLIC` guard around `.claudeCode`.
    var usesSubprocess: Bool {
        #if !KRONOS_PUBLIC
        self == .claudeCode
        #else
        false
        #endif
    }

    /// OpenRouter asks for these on every request (harmless elsewhere; only OpenRouter gets them).
    var extraHeaders: [String: String] {
        switch self {
        case .openRouter: return ["HTTP-Referer": "https://kronos.app", "X-Title": "Kronos"]
        default:          return [:]
        }
    }
}

/// A `TestResult`-shaped value for the AI connection test. No such type exists yet in
/// KronosCore (this file owns Settings only and cannot add one to Core), so this is the
/// local equivalent, shaped the same way, pending a real Core type later.
struct AISettingsTestResult {
    let modelID: String
    let ok: Bool
    let milliseconds: Int
    let servedBy: String?
    let dataPolicy: DataPolicy
    let failure: AIError?
}

@MainActor
@Observable
final class AISettingsController {
    var mode: AIMode
    var provider: AIProvider
    var baseURLText: String
    var modelID: String
    var hasKey: Bool
    var isTesting: Bool = false
    var lastTest: AISettingsTestResult?
    /// True once a Test has passed for the CURRENT (mode, provider, url, model, key)
    /// combination. Any further edit clears it, which is what disables Save again.
    var testPassedForCurrentConfig: Bool = false

    private let isHermetic: Bool
    private let store: any SecretStoring
    private let legacyReader: any LegacySecretReading
    /// Resolved from the selected provider (not a fixed `GhostCLIClient.keychainService`)
    /// so Key/Test/Save all act on the SAME entry the chosen provider will actually be read
    /// from at request time (`AIWiring.configure`).
    private var keyService: String { provider.keychainService }

    /// True when the app-owned item is missing AND a legacy item exists to offer adopting —
    /// this is what shows the "Use the key already in your Keychain" row. Checked with
    /// `hasValue`/a non-secret existence flag where possible; the ONE real read of the
    /// legacy item happens only inside `adoptLegacyKey()`, never here, so simply opening
    /// this tab never triggers the one-time Keychain dialog the legacy item would raise.
    var canAdoptLegacyKey: Bool = false

    init(hermetic: Bool = KronosEnv.isHermetic,
         store: any SecretStoring = KeychainSecretStore(),
         legacyReader: any LegacySecretReading = KeychainLegacySecretReader()) {
        self.isHermetic = hermetic
        self.store = store
        self.legacyReader = legacyReader
        self.mode = AppSettingsStore.aiMode
        self.provider = AppSettingsStore.aiProvider
        self.baseURLText = AppSettingsStore.aiBaseURL
        self.modelID = AppSettingsStore.aiModel
        self.hasKey = hermetic ? true : store.hasValue(AppSettingsStore.aiProvider.keychainService)
        refreshAdoptOffer()
    }

    func markConfigChanged() {
        testPassedForCurrentConfig = false
        lastTest = nil
    }

    /// Switching providers resets the URL to that provider's default and the model to its
    /// first listed choice (empty for `.custom`, where the field is free text) — a stale
    /// GhostCLI model id surviving a switch to OpenRouter would otherwise silently send a
    /// same-provider fallback candidate against the wrong gateway.
    func providerChanged() {
        baseURLText = provider.defaultBaseURL
        modelID = provider.models.first ?? ""
        hasKey = isHermetic ? true : store.hasValue(keyService)
        refreshAdoptOffer()
        markConfigChanged()
    }

    func setKey(_ value: String) {
        guard !isHermetic else { hasKey = true; markConfigChanged(); return }
        try? store.write(value, name: keyService)
        hasKey = true
        refreshAdoptOffer()
        markConfigChanged()
    }

    func removeKey() {
        guard !isHermetic else { hasKey = false; markConfigChanged(); return }
        store.delete(keyService)
        hasKey = false
        refreshAdoptOffer()
        markConfigChanged()
    }

    /// The user's own action ("Use the key already in your Keychain"): reads the legacy item
    /// ONCE (macOS asks once, the user allows it), copies the value into the app-owned item,
    /// and never touches the legacy item again — it is never deleted or renamed, so anything
    /// else still reading it (the eval scripts) is unaffected.
    func adoptLegacyKey() {
        guard !isHermetic, !hasKey else { return }
        guard let legacy = legacyReader.readLegacy(service: provider.legacyKeychainService,
                                                     account: provider.legacyKeychainAccount) else { return }
        setKey(legacy)
    }

    private func refreshAdoptOffer() {
        guard !isHermetic, !hasKey else { canAdoptLegacyKey = false; return }
        // Existence only, never the decrypted value: `existsLegacy` asks for no data back, so
        // it does not raise macOS's access dialog. The one real (decrypting) read of the
        // legacy item happens only inside `adoptLegacyKey()`, on the user's own click.
        canAdoptLegacyKey = legacyReader.existsLegacy(service: provider.legacyKeychainService,
                                                        account: provider.legacyKeychainAccount)
    }

    /// Runs one real triage-shaped probe through Core's GhostCLIClient. In snapshot mode
    /// this never touches the network — it fills in a fixed, calm result immediately.
    ///
    /// Budget raised 12s -> 45s. GhostCLI was measured live answering claude-opus-5 in 13s
    /// and claude-sonnet-5 in 17s; a 12s test budget failed a healthy Opus call every time.
    /// 45s gives real headroom above the slowest measured answer while still bounding the
    /// "Testing…" state.
    func runTest() async {
        guard !isTesting else { return }
        isTesting = true
        defer { isTesting = false }

        if isHermetic {
            lastTest = AISettingsTestResult(modelID: modelID, ok: true, milliseconds: 812,
                                   servedBy: modelID, dataPolicy: .unknown, failure: nil)
            testPassedForCurrentConfig = true
            return
        }

        let client: any AIClient
        #if !KRONOS_PUBLIC
        if provider == .claudeCode {
            client = ClaudeCodeClient(modelID: modelID)
        } else {
            guard let baseURL = URL(string: baseURLText), !modelID.isEmpty else {
                lastTest = AISettingsTestResult(modelID: modelID, ok: false, milliseconds: 0,
                                       servedBy: nil, dataPolicy: .unknown, failure: .badJSON(prefix: "invalid URL or empty model"))
                testPassedForCurrentConfig = false
                return
            }
            client = OpenAICompatibleClient(modelID: modelID, baseURL: baseURL, keyService: keyService,
                                            extraHeaders: provider.extraHeaders)
        }
        #else
        guard let baseURL = URL(string: baseURLText), !modelID.isEmpty else {
            lastTest = AISettingsTestResult(modelID: modelID, ok: false, milliseconds: 0,
                                   servedBy: nil, dataPolicy: .unknown, failure: .badJSON(prefix: "invalid URL or empty model"))
            testPassedForCurrentConfig = false
            return
        }
        client = OpenAICompatibleClient(modelID: modelID, baseURL: baseURL, keyService: keyService,
                                        extraHeaders: provider.extraHeaders)
        #endif
        let request = AIRequest(model: modelID,
                                 messages: [.user("Return only this JSON and nothing else: {\"ok\":true}")],
                                 kind: .triage,
                                 maxTokens: 800,
                                 budgetSeconds: 45)
        let started = ContinuousClock.now
        do {
            let response = try await client.send(request).validated()
            let elapsed = (ContinuousClock.now - started).components
            let ms = Int(elapsed.seconds) * 1000 + Int(elapsed.attoseconds / 1_000_000_000_000_000)
            let ok = response.content.contains("\"ok\"") && response.content.contains("true")
            // Truncate to the same 200-char contract `AIError.badJSON(prefix:)` documents
            // elsewhere (AI-003) — a live CLI/gateway reply can run far longer than that.
            lastTest = AISettingsTestResult(modelID: modelID, ok: ok, milliseconds: ms,
                                   servedBy: response.modelServed ?? modelID,
                                   dataPolicy: .unknown, failure: ok ? nil : .badJSON(prefix: String(response.content.prefix(200))))
            testPassedForCurrentConfig = ok
        } catch let error as AIError {
            lastTest = AISettingsTestResult(modelID: modelID, ok: false, milliseconds: 0,
                                   servedBy: nil, dataPolicy: .unknown, failure: error)
            testPassedForCurrentConfig = false
        } catch {
            lastTest = AISettingsTestResult(modelID: modelID, ok: false, milliseconds: 0,
                                   servedBy: nil, dataPolicy: .unknown, failure: .http(0))
            testPassedForCurrentConfig = false
        }
    }

    /// Persists mode/provider/url/model to UserDefaults. Only called once Save is enabled,
    /// i.e. after `testPassedForCurrentConfig` — enforced by the view disabling the button.
    func save() {
        guard !isHermetic else { return }
        AppSettingsStore.aiMode = mode
        AppSettingsStore.aiProvider = provider
        AppSettingsStore.aiBaseURL = baseURLText
        AppSettingsStore.aiModel = modelID
    }
}

/// Small UserDefaults-backed store for the handful of AI settings that are not secrets.
/// Not a `@Model` / not the Keychain — plain preferences, mirroring `KronosLocale`'s shape.
enum AppSettingsStore {
    private static let modeKey = "kronos.ai.mode"
    private static let providerKey = "kronos.ai.provider"
    private static let urlKey = "kronos.ai.baseURL"
    private static let modelKey = "kronos.ai.model"

    #if KRONOS_PUBLIC
    static let defaultProvider = AIProvider.openRouter
    static let defaultModel = AIProvider.openRouter.models[0]
    #else
    // Was .ghostCLI: GhostCLI's gateway is dead (B1, FINDINGS-FINISH.md). Claude-subscription
    // CLI is the new default for the unset/stale-stored case only — an explicitly stored
    // openRouter/custom/ghostCLI choice in UserDefaults is read as-is below, never overridden.
    static let defaultProvider = AIProvider.claudeCode
    static let defaultModel = "claude-sonnet-5"
    #endif
    static var defaultBaseURL: String { defaultProvider.defaultBaseURL }

    static var aiMode: AIMode {
        get { AIMode(rawValue: KronosEnv.defaults.string(forKey: modeKey) ?? "") ?? .allowAny }
        set { KronosEnv.defaults.set(newValue.rawValue, forKey: modeKey) }
    }
    static var aiProvider: AIProvider {
        get { AIProvider(rawValue: KronosEnv.defaults.string(forKey: providerKey) ?? "") ?? defaultProvider }
        set { KronosEnv.defaults.set(newValue.rawValue, forKey: providerKey) }
    }
    static var aiBaseURL: String {
        get { KronosEnv.defaults.string(forKey: urlKey) ?? defaultBaseURL }
        set { KronosEnv.defaults.set(newValue, forKey: urlKey) }
    }
    static var aiModel: String {
        get { KronosEnv.defaults.string(forKey: modelKey) ?? defaultModel }
        set { KronosEnv.defaults.set(newValue, forKey: modelKey) }
    }
}
