// Kronos/Triage/TriageSettingsLink.swift
// "AI is not set up" on the sort card opens Settings on its AI tab. The Settings scene may not
// exist yet when the card asks, so the tab is also left where Settings reads the last pane it
// showed (`kronos.settings.lastTab`, in the hermetic defaults under a test run), and the same
// request carries the tab name for a Settings window that is already open.
import Foundation
import KronosCore

@MainActor
enum TriageSettingsLink {
    /// The defaults key Settings opens its pane from, and the tab's raw name.
    static let lastTabKey = "kronos.settings.lastTab"
    static let aiTab = "ai"

    static func openAI() {
        KronosEnv.defaults.set(aiTab, forKey: lastTabKey)
        NotificationCenter.default.post(name: .kronosSettingsRequested, object: nil, userInfo: ["tab": aiTab])
    }
}
