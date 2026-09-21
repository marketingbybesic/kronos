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

    /// Where the bearer token comes from. Passed straight through to `MCPServer`, which does
    /// not call it until the first request needs a token (see MCPServer.swift) — so enabling
    /// MCP, including at launch via `applyStoredEnabledState()`, never itself reads the
    /// Keychain. A self-test MUST inject its own: an earlier self-test went through
    /// `MCPKeychain.token()` and made macOS ask to let a binary called "selftest" read the
    /// real `kronos_mcp_token`.
    private let tokenProvider: @Sendable () -> String?

    public init(store: any TaskStoring, ranking: any RankingProviding,
                tokenProvider: @escaping @Sendable () -> String? = { MCPKeychain.token() }) {
        self.store = store
        self.ranking = ranking
        self.tokenProvider = tokenProvider
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

    public func stop() {
        server?.stop()
        server = nil
        isRunning = false
        port = nil
        lastError = nil
    }

    private func startServer() {
        guard server == nil else { return }
        let s = MCPServer(dispatcher: MCPDispatcher(store: store, ranking: ranking), tokenProvider: tokenProvider)
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
                if s.isRunning { return }
            }
        }
    }
}
