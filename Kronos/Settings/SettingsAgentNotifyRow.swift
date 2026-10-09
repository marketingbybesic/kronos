// Kronos/Settings/SettingsAgentNotifyRow.swift
// The Settings > Agents switch for agent-completion notifications: "Finished by <agent>" (or a
// batched count), with a Review action. Off by default. Flipping it on never goes straight to the
// macOS prompt: the first time, a short explanation with Continue comes first (the system prompt
// can be answered once), and if macOS has already said no, the row says where to change that
// instead of leaving a dead switch. Same shape as SettingsNotificationsSection's own toggle, only
// embedded as one row inside the Agents section rather than owning its own section.
import SwiftUI
import AppKit
import KronosCore

struct AgentNotifyRow: View {
    let notifier: AgentDoneNotifications

    init(notifier: AgentDoneNotifications) {
        self.notifier = notifier
    }

    @MainActor init() {
        self.init(notifier: .shared)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x1) {
            HStack(alignment: .top, spacing: Space.x3) {
                VStack(alignment: .leading, spacing: Space.x1) {
                    Text(String(localized: "agents.notify.title"))
                        .font(Typo.metaStrong)
                        .foregroundStyle(Tok.textSecondary)
                    Text(String(localized: "agents.notify.help"))
                        .font(Typo.meta)
                        .foregroundStyle(Tok.textTertiary)
                }
                Spacer(minLength: Space.x4)
                Toggle(isOn: Binding(
                    get: { notifier.isEnabled || notifier.stage == .prePermission },
                    set: { on in Task { await notifier.setEnabled(on) } }
                )) { EmptyView() }
                    .toggleStyle(.switch)
                    .tint(Tok.textPrimary)
                    .labelsHidden()
                    .accessibilityLabel(String(localized: "agents.notify.title"))
                    .uiTestAnchor("settings.agents.notify")
            }
            switch notifier.stage {
            case .prePermission: prePermission
            case .refused: refused
            case .idle: EmptyView()
            }
        }
        .padding(.vertical, Space.x1)
        .task { await notifier.syncWithSystem() }
    }

    private var prePermission: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            Text(String(localized: "agents.notify.pre.title"))
                .font(Typo.rowStrong)
                .foregroundStyle(Tok.textPrimary)
            Text(String(localized: "agents.notify.pre.body"))
                .font(Typo.meta)
                .foregroundStyle(Tok.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.x2) {
                Button(String(localized: "settings.notifications.pre.continue")) {
                    Task { await notifier.continueFromPrePermission() }
                }
                .kButton(.primary, size: .compact)
                .keyboardShortcut(.defaultAction)
                .uiTestAnchor("settings.agents.notify.continue")
                Button(String(localized: "settings.notifications.pre.cancel")) {
                    notifier.cancelPrePermission()
                }
                .kButton(.ghost, size: .compact)
                .keyboardShortcut(.cancelAction)
                .uiTestAnchor("settings.agents.notify.cancel")
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Space.x2)
    }

    private var refused: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            Text(String(localized: "settings.notifications.refused"))
                .font(Typo.meta)
                .foregroundStyle(Tok.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Button(String(localized: "settings.notifications.opensettings")) {
                guard !KronosEnv.isHermetic,
                      let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
                NSWorkspace.shared.open(url)
            }
            .kButton(.secondary, size: .compact)
            .uiTestAnchor("settings.agents.notify.opensettings")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Space.x2)
    }
}
