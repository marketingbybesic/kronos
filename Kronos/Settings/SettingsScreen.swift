// Kronos/Settings/SettingsScreen.swift
// Settings window content: a left tab rail (General / AI / MCP / Data / Shortcuts) on pure
// black, one content pane per tab. Hosted by the app shell in a `Settings { }` scene. Every
// row: label on one grid column, control on the other, one control height per row, quiet
// help text underneath where needed.

import AppKit
import SwiftUI
import KronosCore
import UniformTypeIdentifiers

/// Internal, not private: SettingsSnapshots.swift selects a starting tab (e.g. .ai) for the
/// snapshots that must show the rail with a non-default tab active.
///
/// Order: General, Appearance, Coach, Ordo, Notes (Capture & Notes), AI, MCP ("Claude
/// access" — settings.tab.mcp is already localised to that name, no rename needed), Data,
/// Shortcuts.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, appearance, coach, ordo, notes, ai, mcp, data, shortcuts
    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .general: return "settings.tab.general"
        case .appearance: return "settings.tab.appearance"
        case .coach: return "settings.tab.coach"
        case .ordo: return "settings.tab.ordo"
        case .notes: return "settings.tab.notes"
        case .ai: return "settings.tab.ai"
        case .mcp: return "settings.tab.mcp"
        case .data: return "settings.tab.data"
        case .shortcuts: return "settings.tab.shortcuts"
        }
    }
    var icon: String {
        // "settings"/"keyboard" ARE real Icon.swift map keys (they resolve to
        // "gearshape"/"keyboard" respectively) — a prior comment here named
        // "gearshape"/"keyboard" as the missing raw names, when the actual map key spellings
        // "settings"/"keyboard" were never tried. Verified against Icon.symbol(for:) directly,
        // not from memory.
        switch self {
        case .general: return "settings"
        case .appearance: return "palette"
        case .coach: return "brain"
        case .ordo: return "list-ordered"
        case .notes: return "receipt"
        case .ai: return "sparkles"
        case .mcp: return "server"
        case .data: return "database"
        case .shortcuts: return "keyboard"
        }
    }
}

struct SettingsScreen: View {
    let model: AppModel
    @State private var tab: SettingsTab = .general
    @State private var aiController = AISettingsController()
    private let mcpStatus: MCPStatusProviding

    init(model: AppModel) {
        self.init(model: model, initialTab: .general)
    }

    /// Snapshot-only entry point: SettingsSnapshots.swift needs the rail visible with a
    /// non-default tab selected (e.g. "settings.ai" per ui-common.md G4 "read the rail").
    /// The frozen `init(model:)` above is unaffected and still the only public surface.
    init(model: AppModel, initialTab: SettingsTab) {
        self.model = model
        self._tab = State(initialValue: initialTab)
        self.mcpStatus = ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT"] != nil
            ? FakeMCPStatusProvider(isRunning: true, port: 47311)
            : (AppDelegate.shared?.mcpLive ?? DefaultMCPStatusProvider())
    }

    var body: some View {
        HStack(spacing: 0) {
            railView
            KHairline(vertical: true)
            contentView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Tok.bg)
        .onAppear {
            // Snapshot-only: the "settings.ai" screen must show a passed Test result (G4),
            // and AISettingsController.runTest() is a no-op network call under
            // KRONOS_SNAPSHOT — it fills in a fixed result immediately. Never runs in the
            // real app on a fresh Settings open (that would be a surprise network call).
            guard ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT"] != nil, tab == .ai else { return }
            Task { await aiController.runTest() }
        }
    }

    private var railView: some View {
        VStack(alignment: .leading, spacing: Space.x1) {
            Text(String(localized: "settings.title"))
                .font(Typo.heading)
                .foregroundStyle(Tok.textPrimary)
                .padding(.horizontal, Space.x3)
                .padding(.top, Space.x4)
                .padding(.bottom, Space.x2)
            ForEach(SettingsTab.allCases) { t in
                railRow(t)
            }
            Spacer()
        }
        .frame(width: 168)
        .padding(.horizontal, Space.x2)
        .background(Tok.surface)
    }

    private func railRow(_ t: SettingsTab) -> some View {
        Button {
            tab = t
        } label: {
            HStack(spacing: Space.x2) {
                Icon(t.icon, size: Metrics.iconM)
                    .foregroundStyle(tab == t ? Tok.textPrimary : Tok.textSecondary)
                Text(String(localized: String.LocalizationValue(t.titleKey)))
                    .font(Typo.row)
                    .foregroundStyle(tab == t ? Tok.textPrimary : Tok.textSecondary)
                Spacer()
            }
            .padding(.horizontal, Space.x2)
            .frame(height: Metrics.sidebarRowHeight)
            .background(
                RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                    .fill(tab == t ? Tok.selectedFill : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var contentView: some View {
        // GeometryReader supplies the ONE real width figure: a ScrollView always proposes
        // its content's ideal (unconstrained) width on the non-scrolling axis, so a plain
        // `.frame(maxWidth: .infinity)` inside it has nothing to expand into — every row
        // then sizes to its own widest control instead of sharing the pane's true width,
        // which is exactly why the trailing edges drifted apart (confirmed by screenshot).
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: Space.x6) {
                    switch tab {
                    case .general: SettingsGeneralTab(model: model)
                    case .appearance: SettingsAppearanceTab(model: model)
                    case .coach: SettingsCoachTab(model: model)
                    case .ordo: SettingsOrdoTab(model: model)
                    case .notes: SettingsNotesTab(model: model)
                    case .ai: SettingsAITab(controller: aiController)
                    case .mcp: SettingsMCPTab(status: mcpStatus)
                    case .data: SettingsDataTab(model: model)
                    case .shortcuts: SettingsShortcutsTab()
                    }
                }
                .padding(Space.x6)
                .frame(width: geo.size.width, alignment: .leading)
            }
        }
    }
}

// MARK: - General tab

/// Internal, not private: SettingsSnapshots.swift renders this tab standalone for the
/// "settings" screen key.
struct SettingsGeneralTab: View {
    let model: AppModel
    @State private var languagePref: KronosLocale.Preference = KronosLocale.preference
    @State private var soundsEnabled: Bool = UserDefaults.standard.object(forKey: "kronos.sounds.enabled") == nil
        ? true : UserDefaults.standard.bool(forKey: "kronos.sounds.enabled")
    @State private var launchStatus: SMAppServiceStatus = LaunchAtLogin.currentStatus()
    /// Bumped after a custom-sound pick/reset so `soundCueRow` re-reads `CustomSoundPrefs`
    /// (plain UserDefaults, no observation of its own — see that row's doc comment).
    @State private var customCueRefresh = 0
    private let isHermetic = ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT"] != nil

    var body: some View {
        SettingsSection(title: String(localized: "settings.tab.general")) {
            SettingsRow(label: String(localized: "settings.general.language")) {
                Picker("", selection: $languagePref) {
                    Text(String(localized: "settings.general.language.system")).tag(KronosLocale.Preference.system)
                    Text("English").tag(KronosLocale.Preference.en)
                    Text("Hrvatski").tag(KronosLocale.Preference.hr)
                }
                .labelsHidden()
                // .trailing alignment is required: a native Picker paints at its own
                // intrinsic width inside a wider frame and hugs the LEADING edge by
                // default, which otherwise strands it short of this panel's other rows.
                .frame(width: SettingsMetrics.trailingColumn, alignment: .trailing)
                .onChange(of: languagePref) { _, newValue in KronosLocale.preference = newValue }
            }
            // Always shown, calmly: switching language only fully applies after a relaunch
            // (String(localized:) resolves through the bundle's fixed-at-launch preferred
            // localization — KronosLocale.swift). The help text states the fact; the button
            // is the verb that acts on it, so the two must not repeat the same words.
            SettingsHelpRow {
                Text(String(localized: "settings.general.language.relaunch"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                Spacer()
                Button(String(localized: "settings.general.restart")) { relaunch() }
                    .kButton(.secondary, size: .compact)
            }

            SettingsRow(label: String(localized: "settings.general.permissions")) {
                Button(String(localized: "settings.general.permissions.open")) {
                    PermissionsWindowController.show(model: model, mcpStatus: AppDelegate.shared?.mcpLive ?? DefaultMCPStatusProvider())
                }
                .kButton(.secondary, size: .compact)
            }

            SettingsRow(label: String(localized: "settings.general.sidebar")) {
                KSidebarModeToggle(mode: Binding(
                    get: { model.sidebarIconsOnly ? .iconsOnly : .iconsAndText },
                    set: { newMode in
                        model.sidebarIconsOnly = (newMode == .iconsOnly)
                        model.persist()
                    }
                ))
            }

            SettingsRow(label: String(localized: "settings.sounds.enabled")) {
                Toggle(isOn: $soundsEnabled) { EmptyView() }
                    .toggleStyle(.switch)
                    .tint(Tok.textPrimary)
                    .labelsHidden()
                    .onChange(of: soundsEnabled) { _, v in
                        UserDefaults.standard.set(v, forKey: "kronos.sounds.enabled")
                    }
            }
            VStack(alignment: .leading, spacing: Space.x2) {
                soundCueRow(cue: "task", label: String(localized: "settings.sounds.task"))
                soundCueRow(cue: "subtask", label: String(localized: "settings.sounds.subtask"))
                soundCueRow(cue: "impuls", label: String(localized: "settings.sounds.impuls"))
            }
            .opacity(soundsEnabled ? 1 : 0.4)
            .disabled(!soundsEnabled)
        }

        SettingsSection(title: String(localized: "settings.general.section.startup")) {
            SettingsRow(label: String(localized: "settings.general.launch.label")) {
                Toggle(isOn: Binding(
                    get: { launchStatus == .enabled },
                    set: { toggleLaunchAtLogin($0) }
                )) { EmptyView() }
                    .toggleStyle(.switch)
                    .tint(Tok.textPrimary)
                    .labelsHidden()
                    .disabled(!LaunchAtLogin.isRunningFromApplications && !isHermetic)
            }
            if !LaunchAtLogin.isRunningFromApplications && !isHermetic {
                SettingsHelpRow {
                    Text(String(localized: "settings.general.launch.needs_applications"))
                        .font(Typo.meta)
                        .foregroundStyle(Tok.textTertiary)
                    Spacer()
                }
            }
            SettingsHelpRow {
                Text(String(format: String(localized: "settings.about.version.n"), Self.appVersion) + " · " + Self.buildID)
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                Spacer()
            }
        }
    }

    /// "1.0" in a snapshot run (no real bundle) so the row is never blank while gated; the
    /// real app always has a `CFBundleShortVersionString` from Info.plist.
    private static var appVersion: String {
        // The marketing version stays numeric for macOS; people read the channel name.
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return v.hasPrefix("1.0") ? "Beta 1.0" : v
    }

    /// Short build hash (scripts/write-build-id.sh writes `KronosBuildID` into Info.plist at
    /// build time) — lets a developer tell two dev builds apart at a glance. No localisation:
    /// a hash is not a sentence in any language.
    private static var buildID: String {
        Bundle.main.infoDictionary?["KronosBuildID"] as? String ?? "dev"
    }

    /// One cue: name + preview + "Use my own sound…". `@State private var customCueRefresh`
    /// (declared with the other @State) forces this row to re-read `CustomSoundPrefs.customURL`
    /// right after a pick/reset, since that store is plain UserDefaults with no observation of
    /// its own — matching the pattern `AppearancePrefs` documents for the same reason.
    private func soundCueRow(cue: String, label: String) -> some View {
        HStack(spacing: Space.x2) {
            Text(label)
                .font(Typo.meta)
                .foregroundStyle(Tok.textSecondary)
                .frame(width: SettingsMetrics.cueLabelColumn, alignment: .leading)
            Button {
                SoundPreviewPlayer.play(cue)
            } label: {
                Icon("play", size: Metrics.iconS)
            }
            .kButton(.secondary, size: .compact)
            .frame(minWidth: Metrics.minHit, minHeight: Metrics.minHit)
            .accessibilityLabel(String(localized: "settings.sounds.preview") + " " + label)

            if CustomSoundPrefs.customURL(for: cue) != nil {
                Text(String(localized: "settings.sounds.custom.active"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                Button(String(localized: "settings.sounds.custom.reset")) {
                    CustomSoundPrefs.clearCustom(for: cue)
                    customCueRefresh &+= 1
                }
                .kButton(.ghost, size: .compact)
                .fixedSize()
            } else {
                Button(String(localized: "settings.sounds.custom.pick")) {
                    pickCustomSound(for: cue)
                }
                .kButton(.ghost, size: .compact)
                .fixedSize()
            }
            Spacer()
        }
        .id(customCueRefresh)   // rebuilds this row's "active"/"pick" branch after a change
    }

    private func pickCustomSound(for cue: String) {
        guard !isHermetic else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard CustomSoundPrefs.setCustom(url, for: cue) != nil else { return }
        customCueRefresh &+= 1
    }

    private func toggleLaunchAtLogin(_ on: Bool) {
        guard !isHermetic else { launchStatus = on ? .enabled : .notRegistered; return }
        LaunchAtLogin.setEnabled(on)
        launchStatus = LaunchAtLogin.currentStatus()
    }

    private func relaunch() {
        guard !isHermetic else { return }
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
