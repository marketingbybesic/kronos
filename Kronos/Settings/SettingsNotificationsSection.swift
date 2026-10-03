// Kronos/Settings/SettingsNotificationsSection.swift
// The single switch for block-start notifications. Off by default. Flipping it on never goes
// straight to the macOS prompt: the first time, a short explanation with Continue comes first (the
// system prompt can be answered once), and if macOS has already said no, the section says where to
// change that instead of leaving a dead switch.
import SwiftUI
import AppKit
import KronosCore

struct SettingsNotificationsSection: View {
    let notifier: BlockStartNotifications

    init(notifier: BlockStartNotifications) {
        self.notifier = notifier
    }

    @MainActor init() {
        self.init(notifier: .shared)
    }

    var body: some View {
        SettingsSection(title: String(localized: "settings.notifications.section")) {
            SettingsRow(label: String(localized: "settings.notifications.blockstart")) {
                Toggle(isOn: Binding(
                    get: { notifier.isEnabled || notifier.stage == .prePermission },
                    set: { on in Task { await notifier.setEnabled(on) } }
                )) { EmptyView() }
                    .toggleStyle(.switch)
                    .tint(Tok.textPrimary)
                    .labelsHidden()
                    .accessibilityLabel(String(localized: "settings.notifications.blockstart"))
                    .uiTestAnchor("settings.notify.toggle")
            }
            SettingsHelpRow {
                Text(String(localized: "settings.notifications.blockstart.help"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                Spacer()
            }
            switch notifier.stage {
            case .prePermission: prePermission
            case .refused: refused
            case .idle: EmptyView()
            }
        }
        .task { await notifier.syncWithSystem() }
    }

    private var prePermission: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            Text(String(localized: "settings.notifications.pre.title"))
                .font(Typo.rowStrong)
                .foregroundStyle(Tok.textPrimary)
            Text(String(localized: "settings.notifications.pre.body"))
                .font(Typo.meta)
                .foregroundStyle(Tok.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.x2) {
                Button(String(localized: "settings.notifications.pre.continue")) {
                    Task { await notifier.continueFromPrePermission() }
                }
                .kButton(.primary, size: .compact)
                .keyboardShortcut(.defaultAction)
                .uiTestAnchor("settings.notify.continue")
                Button(String(localized: "settings.notifications.pre.cancel")) {
                    notifier.cancelPrePermission()
                }
                .kButton(.ghost, size: .compact)
                .keyboardShortcut(.cancelAction)
                .uiTestAnchor("settings.notify.cancel")
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
            .uiTestAnchor("settings.notify.opensettings")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Space.x2)
    }
}
