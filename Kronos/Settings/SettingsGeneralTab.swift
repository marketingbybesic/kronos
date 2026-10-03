// Kronos/Settings/SettingsGeneralTab.swift
// General: language, permissions, sidebar, sounds, notes inbox, startup, about and updates.
// Per-event sound files sit under Advanced.

import AppKit
import SwiftUI
import KronosCore
import UniformTypeIdentifiers

// MARK: - General tab

/// Internal, not private: SettingsSnapshots.swift renders this tab standalone for the
/// "settings" screen key.
struct SettingsGeneralTab: View {
    let model: AppModel
    @State private var languagePref: KronosLocale.Preference = KronosLocale.preference
    /// The language in force when this tab opened: the relaunch row only matters once the
    /// user has moved away from it (nothing else in General needs a relaunch).
    @State private var initialLanguagePref: KronosLocale.Preference = KronosLocale.preference
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
                    Text(verbatim: SettingsLanguageName.english).tag(KronosLocale.Preference.en)
                    Text(verbatim: SettingsLanguageName.croatian).tag(KronosLocale.Preference.hr)
                }
                .labelsHidden()
                .accessibilityLabel(String(localized: "settings.general.language"))
                // .trailing alignment is required: a native Picker paints at its own
                // intrinsic width inside a wider frame and hugs the LEADING edge by
                // default, which otherwise strands it short of this panel's other rows.
                .frame(width: SettingsMetrics.trailingColumn, alignment: .trailing)
                .onChange(of: languagePref) { _, newValue in KronosLocale.preference = newValue }
            }
            // Shown only after the language was actually changed: it only fully applies after
            // a relaunch (String(localized:) resolves through the bundle's fixed-at-launch
            // preferred localization — KronosLocale.swift). The help text states the fact; the
            // button is the verb that acts on it, so the two must not repeat the same words.
            if languagePref != initialLanguagePref {
                SettingsHelpRow {
                    Text(String(localized: "settings.general.language.relaunch"))
                        .font(Typo.meta)
                        .foregroundStyle(Tok.textTertiary)
                    Spacer()
                    Button(String(localized: "settings.general.restart")) { relaunch() }
                        .kButton(.secondary, size: .compact)
                }
            }

            SettingsRow(label: String(localized: "settings.general.permissions")) {
                Button(String(localized: "settings.general.permissions.open")) {
                    PermissionsWindowController.show(model: model, mcpStatus: AppDelegate.shared?.mcpLive ?? DefaultMCPStatusProvider())
                }
                .kButton(.secondary, size: .compact)
            }

            SettingsRow(label: String(localized: "settings.general.sidebar")) {
                SidebarModePicker(iconsOnly: Binding(
                    get: { model.sidebarIconsOnly },
                    set: { model.sidebarIconsOnly = $0; model.persist() }
                ))
            }

            SettingsRow(label: String(localized: "settings.sounds.enabled")) {
                Toggle(isOn: $soundsEnabled) { EmptyView() }
                    .toggleStyle(.switch)
                    .tint(Tok.textPrimary)
                    .labelsHidden()
                    .accessibilityLabel(String(localized: "settings.sounds.enabled"))
                    .onChange(of: soundsEnabled) { _, v in
                        UserDefaults.standard.set(v, forKey: "kronos.sounds.enabled")
                    }
            }
        }

        SettingsNotesTab(model: model)

        SettingsSection(title: String(localized: "settings.general.section.startup")) {
            SettingsRow(label: String(localized: "settings.general.launch.label")) {
                Toggle(isOn: Binding(
                    get: { launchStatus == .enabled },
                    set: { toggleLaunchAtLogin($0) }
                )) { EmptyView() }
                    .toggleStyle(.switch)
                    .tint(Tok.textPrimary)
                    .labelsHidden()
                    .accessibilityLabel(String(localized: "settings.general.launch.label"))
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

        SettingsAboutTab(embedded: true)

        // Per-event sound files: most people keep the built-in sounds.
        SettingsAdvanced(tab: "general") {
            SettingsSection(title: String(localized: "settings.tab.sounds")) {
                VStack(alignment: .leading, spacing: Space.x2) {
                    soundCueRow(cue: "task", label: String(localized: "settings.sounds.task"))
                    soundCueRow(cue: "subtask", label: String(localized: "settings.sounds.subtask"))
                    soundCueRow(cue: "impuls", label: String(localized: "settings.sounds.impuls"))
                }
                .opacity(soundsEnabled ? 1 : 0.4)
                .disabled(!soundsEnabled)
                .uiTestAnchor("settings.general.soundcues")
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
        panel.presentOnKeyWindow { url in
            guard CustomSoundPrefs.setCustom(url, for: cue) != nil else { return }
            customCueRefresh &+= 1
        }
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

/// Text-labelled twin of the design system's icon-only `KSidebarModeToggle`: in Settings the
/// choice has to be readable without hovering, so each segment says what the sidebar will show.
private struct SidebarModePicker: View {
    @Binding var iconsOnly: Bool

    var body: some View {
        HStack(spacing: Space.x1) {
            segment(String(localized: "sidebar.mode.icons"), isOn: iconsOnly, value: true)
            segment(String(localized: "sidebar.mode.full"), isOn: !iconsOnly, value: false)
        }
        .padding(Space.x1)
        .background(Tok.controlFill)
        .kBorder(Tok.borderControl, radius: Radius.control)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    private func segment(_ label: String, isOn: Bool, value: Bool) -> some View {
        Button {
            withAnimation(Motion.curve(Motion.medium)) { iconsOnly = value }
        } label: {
            Text(label)
                .font(Typo.meta)
                .foregroundStyle(isOn ? Tok.textPrimary : Tok.textTertiary)
                .lineLimit(1)
                .padding(.horizontal, Space.x3)
                .frame(height: Metrics.controlCompact - 4)
                .background(
                    RoundedRectangle(cornerRadius: Radius.control - Space.x1, style: .continuous)
                        .fill(isOn ? Tok.selectedFill : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}


