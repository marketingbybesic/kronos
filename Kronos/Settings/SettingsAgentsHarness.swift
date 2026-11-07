// Kronos/Settings/SettingsAgentsHarness.swift
// Split out of SettingsAgentsTab.swift (over the 500-line file cap): the global "Agents at once"
// cap stepper and each agent's Harness button + editor (B1/B2, Kronos v1.2 Phase 2 slice B).
// Same split as AgentCapMeters.swift — a focused child view SettingsAgentsList composes in.

import SwiftUI
import KronosCore

/// Global, not per-agent: how many harnesses Kronos may run at once (Settings > Agents).
struct AgentsAtOnceRow: View {
    @State private var agentsAtOnce = RunConcurrencySettings.agentsAtOnce

    var body: some View {
        HStack(alignment: .top, spacing: Space.x3) {
            VStack(alignment: .leading, spacing: Space.x1) {
                Text(String(localized: "agents.harness.cap.title"))
                    .font(Typo.metaStrong)
                    .foregroundStyle(Tok.textSecondary)
                Text(String(localized: "agents.harness.cap.help"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
            }
            Spacer(minLength: Space.x4)
            Stepper(value: $agentsAtOnce, in: 1...4) {
                Text("\(agentsAtOnce)").font(Typo.row).foregroundStyle(Tok.textPrimary)
            }
            .onChange(of: agentsAtOnce) { _, new in RunConcurrencySettings.agentsAtOnce = new }
            .accessibilityLabel(String(localized: "agents.harness.cap.title"))
            .uiTestAnchor("settings.agents.cap")
        }
    }
}

/// The Harness button + its expanded editor for one agent row, shown while `isEditing` is true.
/// Saving pins the path and the slug's default argv template (B1) — argv is a read-only preview,
/// not separately editable here.
struct HarnessEditorRow: View {
    let controller: AgentsSettingsController
    let row: AgentsSettingsController.Row
    @Binding var isEditing: Bool
    @State private var path = ""
    @State private var notFound = false

    var body: some View {
        if isEditing {
            VStack(alignment: .leading, spacing: Space.x2) {
                Text(String(format: String(localized: "agents.harness.title"), row.name))
                    .font(Typo.metaStrong)
                    .foregroundStyle(Tok.textSecondary)
                Text(String(localized: "agents.harness.help"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                HStack(spacing: Space.x2) {
                    KTextField(String(localized: "agents.harness.path.placeholder"), text: $path)
                    Button(String(localized: "agents.harness.find")) { find() }
                        .kButton(.secondary, size: .compact)
                        .uiTestAnchor("settings.agents.harness.find.\(row.slug)")
                }
                if notFound {
                    Text(String(format: String(localized: "agents.harness.find.notfound"), HarnessDefaults.binaryName(forSlug: row.slug)))
                        .font(Typo.meta)
                        .foregroundStyle(Tok.textTertiary)
                }
                Text(String(localized: "agents.harness.argv.label") + " " + row.harnessArgvPreview.joined(separator: " "))
                    .font(Typo.mono)
                    .foregroundStyle(Tok.textTertiary)
                if row.harnessPath.isEmpty {
                    Text(String(localized: "agents.harness.unpinned"))
                        .font(Typo.meta)
                        .foregroundStyle(Tok.textTertiary)
                }
                HStack(spacing: Space.x2) {
                    Button(String(localized: "common.save")) {
                        if controller.pinHarness(slug: row.slug, path: path) { isEditing = false }
                    }
                    .kButton(.secondary, size: .compact)
                    .uiTestAnchor("settings.agents.harness.save")
                    Button(String(localized: "common.cancel")) { isEditing = false }
                        .kButton(.ghost, size: .compact)
                    Spacer(minLength: 0)
                }
            }
            .padding(.top, Space.x1)
            .onAppear { path = row.harnessPath; notFound = false }
        }
    }

    private func find() {
        if let found = controller.findHarnessPath(slug: row.slug) {
            path = found
            notFound = false
        } else {
            notFound = true
        }
    }
}
