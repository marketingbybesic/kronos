// Kronos/Settings/MCPStatusProviding.swift
// Settings cannot reach the running MCPServer instance directly (it lives in Kronos/MCP) —
// this is the seam that gets wired: inject the app's real listener state here once at
// launch. The default implementation reads what it can on its own (Keychain token presence,
// the configured port) so the tab still renders something true before that wiring lands.
//
// Wiring: construct the real listener's status and pass it as
// `SettingsMCPTab(model:, status: AppMCPStatusProvider(listener: myListener))`, or simplest,
// give the app delegate a small struct that reads `MCPServer.isRunning` / `.port` and hands
// that in. Enable/disable is a plain UserDefaults flag AppDelegate reads before starting the
// listener at launch (key below).

import Foundation
import KronosCore

@MainActor
public protocol MCPStatusProviding {
    /// Whether the loopback listener is currently accepting connections.
    var isRunning: Bool { get }
    /// The bound port, once known (tech-stack.md §1.5: 47311...47320 on collision).
    var port: Int? { get }
    /// Why the listener is not running, once known — a calm string ("every port in
    /// 47311...47320 was refused", a bind error) rather than a bare "not running" the user
    /// cannot act on. Nil while running, or before any attempt.
    var lastError: String? { get }
    /// Starts or stops the REAL listener immediately (no relaunch). The default
    /// implementations below only flip the stored preference — `MCPLiveController`
    /// (Kronos/MCP/MCPLiveController.swift) is the one conformer that actually acts on it.
    func setEnabled(_ enabled: Bool)
    /// Called after Settings writes a fresh token to Keychain, so a live listener that
    /// already captured the old token restarts with the new one.
    func tokenDidRegenerate()
}

extension MCPStatusProviding {
    /// Most conformers (the two below) have nothing live to start/stop.
    func setEnabled(_ enabled: Bool) { MCPSettingsKeys.isEnabled = enabled }
    func tokenDidRegenerate() {}
}

/// Reads what it can without the live listener: the bearer token's presence and the
/// enable flag. `isRunning` is best-effort (true only when enabled and a token exists) —
/// inject `MCPLiveController` for an exact, live reading.
///
/// Dead in the shipped app (`AppDelegate.shared` is always set before this type's only two
/// call sites run — see MCPKeychain.swift's header), reachable only from a test harness that
/// constructs `SettingsScreen` without one. Kept only so that path still renders something
/// true if it is ever exercised. `isRunning` reads the non-secret existence flag
/// (`MCPKeychain.hasToken()`), never the Keychain itself.
struct DefaultMCPStatusProvider: MCPStatusProviding {
    var isRunning: Bool {
        MCPSettingsKeys.isEnabled && MCPKeychain.hasToken()
    }
    var port: Int? { isRunning ? 47311 : nil }
    var lastError: String? { nil }
}

/// Fixed status for snapshot mode — never touches the Keychain or a real listener.
struct FakeMCPStatusProvider: MCPStatusProviding {
    let isRunning: Bool
    let port: Int?
    var lastError: String? { nil }
}

enum MCPSettingsKeys {
    /// Read by AppDelegate before starting the loopback listener at launch.
    static let enabledKey = "kronos.mcp.enabled"
    /// This used to be a second, unrelated service string ("com.besic.kronos.mcp") that
    /// nothing ever wrote to — the real token lives under `MCPKeychain`'s service
    /// (`kronos_mcp_token`, the entry that actually exists and that `MCPServer`
    /// authenticates against). Settings reading a different service than the server writes
    /// to is why the tab always showed "not running": one constant, one service.
    static let tokenService = MCPKeychain.service

    /// OFF until the user turns it on in Settings > AI access (MCP). A distributed app must not
    /// open a listener, even a loopback one guarded by a token, that nobody asked for.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
}
