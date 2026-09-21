// Kronos/Settings/SettingsMCPTab.swift
// Status, the copyable `claude mcp add` snippet, Regenerate token, enable/disable.
// The bearer token is inside the snippet by necessity but is
// masked in the UI as bullets; Copy puts the real snippet (with the real token) on the
// pasteboard, which is the whole point of the snippet existing.

import AppKit
import SwiftUI
import KronosCore

struct SettingsMCPTab: View {
    let status: MCPStatusProviding
    @State private var isEnabled: Bool = MCPSettingsKeys.isEnabled
    /// Which snippet's Copy button most recently confirmed — at most one shows "Copied" at a
    /// time (mirrors `didCopy`'s old single-snippet meaning, now that there are two blocks).
    @State private var copiedSnippet: SnippetKind?
    @State private var confirmingRegenerate = false
    private let isHermetic = ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT"] != nil

    private enum SnippetKind { case generic, claudeCLI }

    var body: some View {
        SettingsSection(title: String(localized: "settings.tab.mcp")) {
            SettingsRow(label: String(localized: "settings.data.mcp")) {
                Toggle(isOn: $isEnabled) { EmptyView() }
                    .toggleStyle(.switch)
                    .tint(Tok.textPrimary)
                    .labelsHidden()
                    // Goes through status.setEnabled, not just the UserDefaults flag, so a
                    // live MCPLiveController starts/stops the real listener at once — a
                    // previous version only ever flipped the pref for next launch.
                    .onChange(of: isEnabled) { _, v in status.setEnabled(v) }
                    .uiTestAnchor("settings.mcp.enabled")
            }
            SettingsHelpRow {
                statusLine
                Spacer()
            }

            KHairline().padding(.vertical, Space.x1)

            // MCP access should not be Claude-specific: the copyable block any MCP client can
            // use (Core's own `MCPSettingsSnippet.genericJSON`, already AI-agnostic) is now
            // the PRIMARY snippet; the Claude Code one-liner is kept underneath, explicitly
            // labelled as one example among possible clients rather than the only path shown.
            VStack(alignment: .leading, spacing: Space.x2) {
                Text(String(localized: "settings.mcp.snippet.title", defaultValue: "Connect an MCP client"))
                    .font(Typo.metaStrong)
                    .foregroundStyle(Tok.textSecondary)
                snippetBlock(String(localized: "settings.mcp.snippet.generic", defaultValue: "Works with any MCP client:"),
                             text: maskedGenericSnippet, real: realGenericSnippet, kind: .generic,
                             anchorID: "settings.mcp.copy.generic")
                snippetBlock(String(localized: "settings.mcp.snippet.example", defaultValue: "Example — Claude Code:"),
                             text: maskedCLISnippet, real: realCLISnippet, kind: .claudeCLI,
                             anchorID: "settings.mcp.copy.claudecli")
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
        // A calm reason beats a bare "not running" when one is known — MCPLiveController.lastError
        // carries the real NWListener failure (e.g. every port in range refused) instead of
        // leaving the user to guess.
        if let reason = status.lastError {
            return String(format: String(localized: "settings.mcp.status.stopped.reason"), reason)
        }
        return String(localized: "settings.mcp.status.stopped")
    }

    private var displayToken: String {
        // Only runs while this tab is open (a user action, not launch): reading the
        // app-owned token here is fine, same as any other Settings field showing its
        // current stored value.
        // `token()`, not `loadToken()`: the server creates the token lazily on its first
        // request, so right after MCP was switched on there was none yet and Copy produced
        // "Authorization: Bearer " with nothing after it. While MCP is off, nothing is created.
        if isHermetic { return "0123456789abcdef0123456789abcdef" }
        return (MCPSettingsKeys.isEnabled ? MCPKeychain.token() : MCPKeychain.loadToken()) ?? ""
    }

    private var realGenericSnippet: String { MCPSettingsSnippet.genericJSON(token: displayToken, port: status.port ?? 47311) }
    private var realCLISnippet: String { MCPSettingsSnippet.claudeCLI(token: displayToken, port: status.port ?? 47311) }

    /// Same masking rule for both blocks: the real token never appears on screen, only on the
    /// pasteboard after Copy — masked(text) replaces it with bullets for display only.
    private func masked(_ real: String) -> String {
        guard !displayToken.isEmpty else { return real }
        return real.replacingOccurrences(of: displayToken, with: String(repeating: "•", count: 8))
    }
    private var maskedGenericSnippet: String { masked(realGenericSnippet) }
    private var maskedCLISnippet: String { masked(realCLISnippet) }

    @ViewBuilder
    private func snippetBlock(_ label: String, text: String, real: String, kind: SnippetKind, anchorID: String) -> some View {
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
                    copySnippet(real, kind: kind)
                } label: {
                    HStack(spacing: Space.x1) {
                        // "copy" IS a real Icon.swift map key (-> "doc.on.doc"), verified
                        // against Icon.symbol(for:) directly — the prior comment here was stale.
                        Icon(copiedSnippet == kind ? "check" : "copy", size: Metrics.iconS)
                        Text(copiedSnippet == kind ? String(localized: "settings.data.mcp.copied") : String(localized: "settings.data.mcp.copy"))
                    }
                }
                .kButton(.secondary, size: .compact)
                .uiTestAnchor(anchorID)
            }
        }
    }

    private func copySnippet(_ real: String, kind: SnippetKind) {
        if !isHermetic {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(real, forType: .string)
        }
        copiedSnippet = kind
        Task {
            try? await Task.sleep(for: .seconds(2))
            if copiedSnippet == kind { copiedSnippet = nil }
        }
    }

    private func regenerateToken() {
        guard !isHermetic else { return }
        // Through MCPKeychain (the one place that writes this entry) so the running
        // MCPServer's tokenProvider — the same app-owned store — picks up the new
        // value on its next read, instead of writing a second, unrelated entry.
        MCPKeychain.generateAndStoreToken()
        // A server already running captured the OLD token at init; restart it so the
        // snippet's token and the one the server checks stay the same one.
        status.tokenDidRegenerate()
    }
}
