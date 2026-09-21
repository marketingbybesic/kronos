// Compiled only outside Release: this file exists to render named screens for
// Kronos/Shared/SnapshotHarness.swift, which is itself stubbed out under Release. Wrapping the
// whole registry keeps it out of the shipped binary's strings/symbols without touching any
// file this leaf does not own.
#if !RELEASE
// Kronos/Settings/SettingsSnapshots.swift
// Extra named screens for Kronos/Shared/SnapshotHarness.swift. "settings" and "settings.ai"
// render the REAL SettingsScreen (rail + content) so the rail itself — row spacing, selected
// fill, icon/label alignment — is actually verified; the other three tabs are shown as
// standalone tab content, matching the window's own scroll/padding shell, to measure one
// tab's ink in isolation. All seeding/state happens in .onAppear per ui-common.md; nothing
// here touches the Keychain, network, or SMAppService (KRONOS_SNAPSHOT is checked by every
// controller).

import SwiftUI
import KronosCore

@MainActor
enum SettingsSnapshots {
    static func screens(model: AppModel) -> [String: AnyView] {
        [
            "settings": AnyView(SettingsScreen(model: model, initialTab: .general)),
            "settings.appearance": AnyView(SettingsScreen(model: model, initialTab: .appearance)),
            "settings.coach": AnyView(SettingsScreen(model: model, initialTab: .coach)),
            "settings.ordo": AnyView(SettingsScreen(model: model, initialTab: .ordo)),
            "settings.notes": AnyView(SettingsScreen(model: model, initialTab: .notes)),
            "settings.ai": AnyView(SettingsScreen(model: model, initialTab: .ai)),
            "settings.mcp": AnyView(SettingsTabPreview {
                SettingsMCPTab(status: FakeMCPStatusProvider(isRunning: true, port: 47311))
            }),
            "settings.data": AnyView(SettingsTabPreview { SettingsDataTab(model: model) }),
            "settings.shortcuts": AnyView(SettingsScreen(model: model, initialTab: .shortcuts)),
        ]
    }
}

/// Wraps a single tab's content in the same scroll/padding shell SettingsScreen gives it,
/// so a standalone tab snapshot matches what it looks like inside the real window.
private struct SettingsTabPreview<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.x6) {
                content()
            }
            .padding(Space.x6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Tok.bg)
    }
}
#endif
