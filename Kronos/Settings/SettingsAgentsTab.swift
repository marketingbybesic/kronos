// Kronos/Settings/SettingsAgentsTab.swift
// One block per agent (Claude Code, Codex, Relay, ...): whether it is allowed in, what it may do,
// when it last worked and how much it wrote this week, how it hears back from you, and the safety
// valves (new token, revert today's changes, remove). Everything an agent can be given or have
// taken away is decided here, never over MCP.

import AppKit
import SwiftUI
import KronosCore

/// Opens the agent list lazily: the device-local store is only touched once this tab is shown.
struct SettingsAgentsTab: View {
    @State private var controller: AgentsSettingsController?
    private let make: () -> AgentsSettingsController

    /// `eager` builds the controller at once (snapshots use fixtures, which cost nothing).
    init(eager: Bool = false, make: @escaping () -> AgentsSettingsController) {
        self.make = make
        self._controller = State(initialValue: eager ? make() : nil)
    }

    // The placeholder is what makes this a real view before the controller exists: a modifier on an
    // EmptyView never fires, which left the pane blank for good.
    var body: some View {
        Group {
            if let controller {
                SettingsAgentsList(controller: controller)
            } else {
                Color.clear.frame(height: 1)
            }
        }
        .task { if controller == nil { controller = make() } }
    }
}

struct SettingsAgentsList: View {
    @State private var controller: AgentsSettingsController
    @State private var newName = ""
    @State private var confirming: Confirmation?
    @State private var editing: String?
    @State private var kind: AgentsSettingsController.DeliveryKind = .off
    @State private var text = ""
    @State private var invalid = false
    @State private var copied = false

    private enum Confirmation: Equatable { case token(String), revert(String), remove(String), fullControl(String) }

    init(controller: AgentsSettingsController) {
        self._controller = State(initialValue: controller)
    }

    var body: some View {
        SettingsSection(title: String(localized: "agents.section")) {
            SettingsHelpRow {
                Text(String(localized: "agents.intro"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                Spacer()
            }
            .uiTestAnchor("settings.agents.intro")
            if controller.unavailable {
                Text(String(localized: "agents.unavailable"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
            } else if controller.rows.isEmpty {
                Text(String(localized: "agents.empty"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                    .padding(.vertical, Space.x2)
            }
            ForEach(controller.rows) { row in
                KHairline().padding(.vertical, Space.x1)
                agentBlock(row)
            }
            KHairline().padding(.vertical, Space.x1)
            addRow
            if let message = controller.message {
                Text(message)
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, Space.x1)
            }
        }
        .onAppear { controller.refresh() }
    }

    // MARK: one agent

    private func agentBlock(_ row: AgentsSettingsController.Row) -> some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            HStack(spacing: Space.x3) {
                Text(row.glyph)
                    .font(Typo.metaStrong)
                    .foregroundStyle(Tok.textSecondary)
                    .frame(width: Metrics.controlCompact, height: Metrics.controlCompact)
                    .background(Circle().fill(Tok.controlFill))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.x1) {
                    Text(row.name)
                        .font(Typo.rowStrong)
                        .foregroundStyle(Tok.textPrimary)
                    Text(lastSeenText(row))
                        .font(Typo.meta)
                        .foregroundStyle(Tok.textTertiary)
                }
                Spacer(minLength: Space.x4)
                Toggle(isOn: Binding(get: { row.isEnabled }, set: { controller.setEnabled($0, slug: row.slug) })) { EmptyView() }
                    .toggleStyle(.switch)
                    .tint(Tok.textPrimary)
                    .labelsHidden()
                    .accessibilityLabel(String(format: String(localized: "agents.enabled"), row.name))
                    .uiTestAnchor("settings.agents.enabled.\(row.slug)")
            }
            detail(String(format: String(localized: "agents.row.writes"), row.writesWeek))
            detail(row.isShared ? String(localized: "agents.row.legacy")
                                : String(format: String(localized: "agents.row.scopes"), scopeList(row.scopes)))
            if !row.isShared { fullControlRow(row) }
            if row.undelivered > 0 {
                detail(String(format: String(localized: "agents.row.undelivered"), row.undelivered))
            }
            if row.dead > 0 {
                detail(String(format: String(localized: "agents.row.dead"), row.dead))
            }
            actions(row)
            if editing == row.slug { deliveryEditor(row) }
            confirmation(row)
        }
        .padding(.vertical, Space.x1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Off by default. Turning it on asks first; turning it off is immediate.
    private func fullControlRow(_ row: AgentsSettingsController.Row) -> some View {
        HStack(alignment: .top, spacing: Space.x3) {
            VStack(alignment: .leading, spacing: Space.x1) {
                Text(String(localized: "agents.fullcontrol.title"))
                    .font(Typo.metaStrong)
                    .foregroundStyle(Tok.textSecondary)
                Text(String(localized: "agents.fullcontrol.help"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
            }
            Spacer(minLength: Space.x4)
            Toggle(isOn: Binding(get: { row.scopes.has(.writeAll) },
                                 set: { on in
                                     if on { confirming = .fullControl(row.slug) } else { controller.setFullControl(false, slug: row.slug) }
                                 })) { EmptyView() }
                .toggleStyle(.switch)
                .tint(Tok.textPrimary)
                .labelsHidden()
                .accessibilityLabel(String(format: String(localized: "agents.fullcontrol.label"), row.name))
                .uiTestAnchor("settings.agents.fullcontrol.\(row.slug)")
        }
    }

    private func detail(_ s: String) -> some View {
        Text(s)
            .font(Typo.meta)
            .foregroundStyle(Tok.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actions(_ row: AgentsSettingsController.Row) -> some View {
        HStack(spacing: Space.x2) {
            Button(String(localized: "agents.delivery")) { toggleEditor(row) }
                .kButton(.secondary, size: .compact)
                .uiTestAnchor("settings.agents.delivery.\(row.slug)")
            if !row.isShared {
                Button(String(localized: "agents.token.new")) { confirming = .token(row.slug) }
                    .kButton(.secondary, size: .compact)
            }
            Button(String(localized: "agents.revert")) { confirming = .revert(row.slug) }
                .kButton(.secondary, size: .compact)
                .uiTestAnchor("settings.agents.revert.\(row.slug)")
            Button(String(localized: "agents.remove")) { confirming = .remove(row.slug) }
                .kButton(.ghost, size: .compact)
            Spacer(minLength: 0)
        }
    }

    // MARK: confirmation

    @ViewBuilder
    private func confirmation(_ row: AgentsSettingsController.Row) -> some View {
        if let c = confirming, c == .token(row.slug) || c == .revert(row.slug) || c == .remove(row.slug) || c == .fullControl(row.slug) {
            VStack(alignment: .leading, spacing: Space.x2) {
                Text(confirmText(c, row))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textSecondary)
                HStack(spacing: Space.x2) {
                    Button(confirmAction(c)) { perform(c) }
                        .kButton(.secondary, size: .compact)
                        .uiTestAnchor("settings.agents.confirm.\(row.slug)")
                    Button(String(localized: "common.cancel")) { confirming = nil }
                        .kButton(.ghost, size: .compact)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func confirmText(_ c: Confirmation, _ row: AgentsSettingsController.Row) -> String {
        switch c {
        case .token: return String(localized: "agents.token.new.confirm")
        case .revert: return String(format: String(localized: "agents.revert.confirm"), row.name)
        case .remove: return String(format: String(localized: "agents.remove.confirm"), row.name)
        case .fullControl: return String(format: String(localized: "agents.fullcontrol.confirm"), row.name)
        }
    }

    private func confirmAction(_ c: Confirmation) -> String {
        switch c {
        case .token: return String(localized: "agents.token.new")
        case .revert: return String(localized: "agents.revert.action")
        case .remove: return String(localized: "agents.remove")
        case .fullControl: return String(localized: "agents.fullcontrol.enable")
        }
    }

    private func perform(_ c: Confirmation) {
        switch c {
        case .token(let slug): controller.rotateToken(slug: slug)
        case .revert(let slug): controller.revertToday(slug: slug)
        case .remove(let slug): controller.remove(slug: slug)
        case .fullControl(let slug): controller.setFullControl(true, slug: slug)
        }
        confirming = nil
    }

    // MARK: delivery editor

    private func toggleEditor(_ row: AgentsSettingsController.Row) {
        if editing == row.slug { editing = nil; return }
        editing = row.slug
        kind = AgentsSettingsController.kind(of: row.target)
        text = AgentsSettingsController.text(of: row.target)
        invalid = false
    }

    private func deliveryEditor(_ row: AgentsSettingsController.Row) -> some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            Text(String(format: String(localized: "agents.delivery.title"), row.name))
                .font(Typo.metaStrong)
                .foregroundStyle(Tok.textSecondary)
            Picker("", selection: $kind) {
                Text(String(localized: "agents.delivery.off")).tag(AgentsSettingsController.DeliveryKind.off)
                Text(String(localized: "agents.delivery.webhook")).tag(AgentsSettingsController.DeliveryKind.webhook)
                Text(String(localized: "agents.delivery.ntfy")).tag(AgentsSettingsController.DeliveryKind.ntfy)
                Text(String(localized: "agents.delivery.command")).tag(AgentsSettingsController.DeliveryKind.command)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .onChange(of: kind) { _, _ in invalid = false }
            if kind != .off {
                KTextField(placeholder, text: $text)
                Text(help)
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
            }
            if kind == .webhook { secretRow(row) }
            if invalid {
                Text(String(localized: "agents.delivery.invalid"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textSecondary)
            }
            HStack(spacing: Space.x2) {
                Button(String(localized: "common.save")) {
                    if controller.saveDelivery(slug: row.slug, kind: kind, text: text) { editing = nil } else { invalid = true }
                }
                .kButton(.secondary, size: .compact)
                .uiTestAnchor("settings.agents.delivery.save")
                Button(String(localized: "common.cancel")) { editing = nil }
                    .kButton(.ghost, size: .compact)
                Spacer(minLength: 0)
            }
        }
        .padding(.top, Space.x1)
    }

    @ViewBuilder
    private func secretRow(_ row: AgentsSettingsController.Row) -> some View {
        HStack(spacing: Space.x2) {
            Button(String(localized: "agents.delivery.secret.new")) { controller.newSecret(slug: row.slug) }
                .kButton(.secondary, size: .compact)
            Spacer(minLength: 0)
        }
        if let secret = controller.shownSecret[row.slug] {
            KPanel(padding: Space.x3) {
                HStack(alignment: .top) {
                    Text(String(format: String(localized: "agents.delivery.secret.shown"), secret))
                        .font(Typo.mono)
                        .foregroundStyle(Tok.textPrimary)
                        .textSelection(.enabled)
                    Spacer(minLength: Space.x2)
                    Button {
                        copy(secret)
                    } label: {
                        HStack(spacing: Space.x1) {
                            Icon(copied ? "check" : "copy", size: Metrics.iconS)
                            Text(copied ? String(localized: "settings.data.mcp.copied") : String(localized: "settings.data.mcp.copy"))
                        }
                    }
                    .kButton(.secondary, size: .compact)
                }
            }
        }
    }

    private var placeholder: String {
        switch kind {
        case .off, .webhook: return String(localized: "agents.delivery.webhook.placeholder")
        case .ntfy: return String(localized: "agents.delivery.ntfy.placeholder")
        case .command: return String(localized: "agents.delivery.command.placeholder")
        }
    }

    private var help: String {
        switch kind {
        case .off: return ""
        case .webhook: return String(localized: "agents.delivery.help.webhook")
        case .ntfy: return String(localized: "agents.delivery.help.ntfy")
        case .command: return String(localized: "agents.delivery.help.command")
        }
    }

    private func copy(_ secret: String) {
        if ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT"] == nil {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(secret, forType: .string)
        }
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    // MARK: add

    private var addRow: some View {
        HStack(spacing: Space.x2) {
            KTextField(String(localized: "agents.add.placeholder"), text: $newName)
            Button(String(localized: "agents.add")) {
                if controller.add(name: newName) { newName = "" }
            }
            .kButton(.secondary, size: .compact)
            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            .uiTestAnchor("settings.agents.add")
        }
    }

    // MARK: text

    private func lastSeenText(_ row: AgentsSettingsController.Row) -> String {
        guard let seen = row.lastSeen else { return String(localized: "agents.row.neverseen") }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        // Snapshots render a fixed clock so the picture never depends on the day it was taken.
        let now = ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT"] != nil
            ? Date(timeIntervalSince1970: 1_790_000_000) : Date()
        return String(format: String(localized: "agents.row.lastseen"), f.localizedString(for: seen, relativeTo: now))
    }

    private func scopeList(_ s: AgentScopes) -> String {
        var parts: [String] = []
        if s.has(.read) { parts.append(String(localized: "agents.scope.read")) }
        if s.has(.propose) { parts.append(String(localized: "agents.scope.propose")) }
        if s.has(.writeOwn) { parts.append(String(localized: "agents.scope.writeown")) }
        if s.has(.comment) { parts.append(String(localized: "agents.scope.comment")) }
        if s.has(.writeTrusted) { parts.append(String(localized: "agents.scope.trusted")) }
        if s.has(.writeAll) { parts.append(String(localized: "agents.scope.writeall")) }
        if s.has(.rulesPropose) { parts.append(String(localized: "agents.scope.rules")) }
        return parts.isEmpty ? String(localized: "agents.scope.none") : parts.joined(separator: ", ")
    }
}
