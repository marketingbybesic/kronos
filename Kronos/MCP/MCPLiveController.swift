// Owns the live `MCPServer` lifecycle so Settings > MCP reflects the REAL listener and the
// enable/disable switch takes effect immediately, no relaunch.
//
// Before this type existed, Settings only flipped a UserDefaults flag
// (`MCPSettingsKeys.isEnabled`) and the status shown came from a one-shot
// `DefaultMCPStatusProvider()` constructed once at launch (SettingsScreen.swift,
// PermissionsWindow.swift) — it could never reflect a listener started or stopped
// after that point. This type is the single live source of truth: `@Observable` so
// SwiftUI re-renders the moment the listener's state changes, and it does the
// start/stop itself so the switch acts at once.
import Foundation
import KronosCore

@MainActor
@Observable
public final class MCPLiveController: MCPStatusProviding {
    public private(set) var isRunning = false
    public private(set) var port: Int?
    public private(set) var lastError: String?

    private let store: any TaskStoring
    private let ranking: any RankingProviding
    private var server: MCPServer?
    private let endpointDirectory: URL
    /// Keeps macOS from App-Napping the listener of a hidden (--mcp-background) app.
    private var activity: NSObjectProtocol?

    /// Where the bearer token comes from. Passed straight through to `MCPServer`, which does
    /// not call it until the first request needs a token (see MCPServer.swift) — so enabling
    /// MCP, including at launch via `applyStoredEnabledState()`, never itself reads the
    /// Keychain. A self-test MUST inject its own: an earlier self-test went through
    /// `MCPTokenStore.token()` and made macOS ask to let a binary called "selftest" read the
    /// real `kronos_mcp_token`.
    private let tokenProvider: @Sendable () -> String?

    /// Where the agent registry comes from. `.standard` opens the device-local store of this
    /// build's folder (the app); `.none` runs without agent bookkeeping (every caller is the
    /// person); `.custom` is a hub the caller built (tests, over an in-memory store).
    public enum AgentHubSource { case standard, none, custom(AgentHub) }
    private let hubSource: AgentHubSource
    /// The live hub once the server runs; Settings > Agents reads it.
    public private(set) var hub: AgentHub?
    /// What `next` offers: the list on screen. Installed by the app's binding (see MCPAppBinding).
    public var nextProvider: (@MainActor () -> MCPNextCandidates?)?

    /// Injecting a `tokenProvider` is a test or self-test: such a controller never opens the
    /// device-local store unless it is given a hub explicitly.
    public init(store: any TaskStoring, ranking: any RankingProviding,
                tokenProvider: (@Sendable () -> String?)? = nil,
                agentHub: AgentHubSource? = nil,
                endpointDirectory: URL = MCPEndpointFile.defaultDirectory()) {
        self.endpointDirectory = endpointDirectory
        self.store = store
        self.ranking = ranking
        self.tokenProvider = tokenProvider ?? { MCPTokenStore.token() }
        self.hubSource = agentHub ?? (tokenProvider == nil ? .standard : AgentHubSource.none)
    }

    /// Called once at launch: starts the listener only if the stored preference says so.
    /// Reads no secret itself — see `setEnabled`.
    public func applyStoredEnabledState() {
        setEnabled(MCPSettingsKeys.isEnabled)
    }

    /// The switch in Settings calls this directly — starts the real listener immediately.
    /// Binding the socket needs no token (`MCPServer` only calls `tokenProvider` once a
    /// request actually arrives), so this never blocks on, or even touches, the Keychain —
    /// safe to call from the main thread at launch as well as from a Settings toggle.
    public func setEnabled(_ enabled: Bool) {
        MCPSettingsKeys.isEnabled = enabled
        guard enabled else { stop(); return }
        startServer()
    }

    /// Regenerating the token invalidates whatever the running server cached — restart it so
    /// the new token takes effect immediately instead of only on the next request.
    public func tokenDidRegenerate() {
        guard server != nil else { return }
        stop()
        setEnabled(true)
    }

    /// The app's own wiring (the list on screen for `next`, webhook delivery) lives in
    /// `MCPAppBinding`, which only the app target compiles. It is found by its Objective-C name so
    /// this file builds, and the self-tests run, without the rest of the app.
    private func callAppBinding(_ selector: String) {
        guard let cls = NSClassFromString("KronosMCPAppBinding") as? NSObject.Type else { return }
        _ = cls.perform(NSSelectorFromString(selector), with: self)
    }

    public func stop() {
        if server != nil { callAppBinding("detachController:") }
        server?.stop()
        server = nil
        isRunning = false
        port = nil
        lastError = nil
        MCPEndpointFile.remove(directory: endpointDirectory)
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
    }

    private func startServer() {
        guard server == nil else { return }
        let dispatcher = MCPDispatcher(store: store, ranking: ranking)
        switch hubSource {
        case .standard:
            hub = hub ?? (try? AgentHub(directory: KronosStore.containerDirectory()))
        case .custom(let h): hub = h
        case .none: hub = nil
        }
        dispatcher.hub = hub
        dispatcher.nextProvider = { [weak self] in self?.nextProvider?() }
        callAppBinding("attachController:")
        let s = MCPServer(dispatcher: dispatcher, tokenProvider: tokenProvider)
        // The token lives in a 0600 file now (no Keychain dialog), so it is created the moment
        // the server starts: the stdio bridge reads it before its first request.
        _ = tokenProvider()
        s.start()
        server = s
        observe(s)
    }

    /// `MCPServer`'s own `isRunning`/`boundPort` settle asynchronously once the listener
    /// binds (or fails every port in range); poll briefly so this controller's `@Observable`
    /// properties — and everything reading them — pick up the real outcome. Stops polling
    /// once the listener reports running, or after ~2 s if every port was taken.
    private func observe(_ s: MCPServer) {
        Task { [weak self] in
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.server === s else { return }
                self.isRunning = s.isRunning
                self.port = s.boundPort.map(Int.init)
                self.lastError = s.lastError
                if s.isRunning {
                    if self.activity == nil {
                        self.activity = ProcessInfo.processInfo.beginActivity(options: .background, reason: "MCP server")
                    }
                    let bundleID = Bundle.main.bundleIdentifier ?? "com.besic.kronos"
                    try? MCPEndpointFile.write(port: Int(s.boundPort ?? 47311), bundleID: bundleID,
                                               directory: self.endpointDirectory)
                    return
                }
            }
            // Every port refused: no stale endpoint file.
            MCPEndpointFile.remove(directory: self?.endpointDirectory ?? MCPEndpointFile.defaultDirectory())
        }
    }
}
