// Kronos/Settings/SettingsMCPTab.swift
// Status, the bridge command per AI tool (Claude Code, Codex, Hermes, Claude Desktop), a
// "Connect all local AI tools" button, Regenerate token, enable/disable.
// The snippets carry NO token: the bridge (Contents/MacOS/kronos-mcp) reads the token and port
// from the app's own secrets folder on every request, so nothing secret is ever shown or pasted.

import AppKit
import SwiftUI
import KronosCore

struct SettingsMCPTab: View {
    let status: MCPStatusProviding
    @State private var isEnabled: Bool = MCPSettingsKeys.isEnabled
    /// Which snippet's Copy button most recently confirmed; at most one shows "Copied".
    @State private var copiedSnippet: SnippetKind?
    @State private var confirmingRegenerate = false
    @State private var connecting = false
    @State private var connectSummary: String?
    private let isHermetic = ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT"] != nil

    private enum SnippetKind: Hashable {
        case claudeCode, codex, desktop
        #if !KRONOS_PUBLIC
        case hermes
        #endif
    }

    var body: some View {
        SettingsSection(title: String(localized: "settings.tab.mcp")) {
            SettingsRow(label: String(localized: "settings.data.mcp")) {
                Toggle(isOn: $isEnabled) { EmptyView() }
                    .toggleStyle(.switch)
                    .tint(Tok.textPrimary)
                    .labelsHidden()
                    // Goes through status.setEnabled, not just the UserDefaults flag, so a
                    // live MCPLiveController starts/stops the real listener at once.
                    .onChange(of: isEnabled) { _, v in status.setEnabled(v) }
                    .uiTestAnchor("settings.mcp.enabled")
            }
            SettingsHelpRow {
                statusLine
                Spacer()
            }

            KHairline().padding(.vertical, Space.x1)

            SettingsTrailingRow {
                Button(connecting ? String(localized: "settings.mcp.connecting") : String(localized: "settings.mcp.connectall")) {
                    connectAll()
                }
                .kButton(.secondary, size: .compact)
                .disabled(connecting)
                .uiTestAnchor("settings.mcp.connectall")
            }
            .padding(.top, Space.x1)
            if let connectSummary {
                Text(connectSummary)
                    .font(Typo.mono)
                    .foregroundStyle(Tok.textTertiary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if confirmingRegenerate {
                HStack {
                    Text(String(localized: "settings.mcp.token.regen.confirm"))
                        .font(Typo.meta)
                        .foregroundStyle(Tok.textTertiary)
                    Spacer(minLength: Space.x4)
                    Button(String(localized: "settings.data.mcp.token.regen")) {
                        regenerateToken()
                        confirmingRegenerate = false
                    }
                    .kButton(.secondary, size: .compact)
                    .uiTestAnchor("settings.mcp.token.regen.confirm")
                    Button(String(localized: "common.cancel")) { confirmingRegenerate = false }
                        .kButton(.ghost, size: .compact)
                }
                .padding(.top, Space.x1)
            } else {
                SettingsTrailingRow {
                    Button(String(localized: "settings.data.mcp.token.regen")) { confirmingRegenerate = true }
                        .kButton(.secondary, size: .compact)
                        .uiTestAnchor("settings.mcp.token.regen")
                }
                .padding(.top, Space.x1)
            }
        }

        SettingsDisclosure(id: "manual.mcp",
                           title: String(localized: "settings.mcp.manual.title")) {
            SettingsSection(title: String(localized: "settings.mcp.snippet.title")) {
                VStack(alignment: .leading, spacing: Space.x2) {
                    Text(String(localized: "settings.mcp.snippet.bridge"))
                        .font(Typo.meta)
                        .foregroundStyle(Tok.textTertiary)
                    KPanel(padding: Space.x3) {
                        Text(bridgePath)
                            .font(Typo.mono)
                            .foregroundStyle(Tok.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    snippetBlock(String(localized: "settings.mcp.snippet.claudecode"),
                                 MCPSettingsSnippet.bridgeClaudeCode(bridge: bridgePath, name: serverName), .claudeCode)
                    snippetBlock(String(localized: "settings.mcp.snippet.codex"),
                                 MCPSettingsSnippet.bridgeCodexTOML(bridge: bridgePath, name: serverName), .codex)
                    #if !KRONOS_PUBLIC
                    snippetBlock(String(localized: "settings.mcp.snippet.hermes"),
                                 MCPSettingsSnippet.bridgeHermesYAML(bridge: bridgePath, name: serverName), .hermes)
                    #endif
                    snippetBlock(String(localized: "settings.mcp.snippet.desktop"),
                                 MCPSettingsSnippet.bridgeDesktopJSON(bridge: bridgePath, name: serverName), .desktop)
                }
            }
        }
    }

    private var statusLine: some View {
        HStack(spacing: Space.x2) {
            Circle()
                .fill(status.isRunning ? Tok.textPrimary : Tok.textDisabled)
                .frame(width: 6, height: 6)
            Text(statusText)
                .font(Typo.meta)
                .foregroundStyle(Tok.textTertiary)
        }
    }

    private var statusText: String {
        if let port = status.port, status.isRunning {
            return String(format: String(localized: "settings.mcp.status.running"), String(port))
        }
        // A calm reason beats a bare "not running" when one is known (the real listener failure).
        if let reason = status.lastError {
            return String(format: String(localized: "settings.mcp.status.stopped.reason"), reason)
        }
        return String(localized: "settings.mcp.status.stopped")
    }

    // MARK: bridge

    /// The demo registers as "kronos-demo" so it never replaces the real entry (same rule as
    /// connect-harnesses.mjs).
    private var serverName: String { (Bundle.main.bundleIdentifier ?? "").hasSuffix(".demo") ? "kronos-demo" : "kronos" }

    private var bridgePath: String {
        if isHermetic { return "/Applications/Kronos.app/Contents/MacOS/kronos-mcp" }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/kronos-mcp").path
    }

    private func snippetBlock(_ label: String, _ text: String, _ kind: SnippetKind) -> some View {
        VStack(alignment: .leading, spacing: Space.x1) {
            Text(label)
                .font(Typo.meta)
                .foregroundStyle(Tok.textTertiary)
            KPanel(padding: Space.x3) {
                HStack(alignment: .top) {
                    Text(text)
                        .font(Typo.mono)
                        .foregroundStyle(Tok.textPrimary)
                        .textSelection(.enabled)
                    Spacer(minLength: Space.x2)
                    Button {
                        copySnippet(text, kind: kind)
                    } label: {
                        HStack(spacing: Space.x1) {
                            Icon(copiedSnippet == kind ? "check" : "copy", size: Metrics.iconS)
                            Text(copiedSnippet == kind ? String(localized: "settings.data.mcp.copied") : String(localized: "settings.data.mcp.copy"))
                        }
                    }
                    .kButton(.secondary, size: .compact)
                    .uiTestAnchor("settings.mcp.copy.\(String(describing: kind))")
                }
            }
        }
    }

    private func copySnippet(_ text: String, kind: SnippetKind) {
        if !isHermetic {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        copiedSnippet = kind
        Task {
            try? await Task.sleep(for: .seconds(2))
            if copiedSnippet == kind { copiedSnippet = nil }
        }
    }

    /// Runs the bundled connect-harnesses.mjs with node (PATH, then Homebrew). The script backs
    /// every config up first and never prints secrets, so its stdout is shown as is.
    private func connectAll() {
        guard !isHermetic, !connecting else { return }
        guard let script = Bundle.main.url(forResource: "connect-harnesses", withExtension: "mjs"),
              let node = Self.findNode() else {
            connectSummary = String(localized: "settings.mcp.connect.unavailable")
            return
        }
        connecting = true
        let app = Bundle.main.bundleURL.path
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: node)
            p.arguments = [script.path, "--app", app]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            try? p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let out = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            await MainActor.run {
                connectSummary = out
                connecting = false
            }
        }
    }

    private static func findNode() -> String? {
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return (path + ["/opt/homebrew/bin", "/usr/local/bin"])
            .map { $0 + "/node" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func regenerateToken() {
        guard !isHermetic else { return }
        // Through MCPTokenStore (the one place that writes this entry); the bridge re-reads the
        // token file on every request and retries once on 401, so connected tools keep working.
        MCPTokenStore.generateAndStoreToken()
        // A server already running captured the OLD token at init; restart it.
        status.tokenDidRegenerate()
    }
}
