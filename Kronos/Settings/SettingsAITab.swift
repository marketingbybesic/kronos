// Kronos/Settings/SettingsAITab.swift
// Mode, gateway URL, model, API key, and the mandatory Test gate.
// A changed model/URL/key cannot be saved until a Test against that exact configuration has
// passed — Save stays disabled until `controller.testPassedForCurrentConfig` is true.

import SwiftUI
import KronosCore

struct SettingsAITab: View {
    @Bindable var controller: AISettingsController
    @State private var keyInput: String = ""
    @State private var isEditingKey: Bool = false
    /// True while the model row shows the free-text field instead of the presets popup
    /// (picked "Other…", or the stored model id is not one of the provider's own). Reset
    /// whenever the provider changes so a leftover custom id from a different provider
    /// never keeps this row stuck in text-entry mode.
    @State private var isEditingCustomModel: Bool = false

    var body: some View {
        SettingsSection(title: String(localized: "settings.tab.ai")) {
            SettingsRow(label: String(localized: "settings.ai.usefor")) {
                Picker("", selection: $controller.mode) {
                    Text(String(localized: "ai.mode.off")).tag(AIMode.off)
                    Text(String(localized: "ai.mode.private_only")).tag(AIMode.privateOnly)
                    Text(String(localized: "ai.mode.allow_any")).tag(AIMode.allowAny)
                }
                .labelsHidden()
                // Same width as the Base URL field and the Model popup below, so every
                // control in this section ends at the identical trailing edge. A native
                // Picker paints at its own intrinsic (content) width inside a wider frame
                // and does not stretch to fill it — .trailing alignment is required or it
                // hugs the LEADING edge of the frame instead, landing short of the field.
                .frame(width: SettingsMetrics.trailingColumn, alignment: .trailing)
                .onChange(of: controller.mode) { _, _ in controller.markConfigChanged() }
                .uiTestAnchor("settings.ai.mode")
            }
            SettingsHelpRow {
                Text(modeNote)
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                Spacer()
            }

            if controller.mode != .off {
                SettingsRow(label: String(localized: "settings.ai.provider")) {
                    Picker("", selection: $controller.provider) {
                        ForEach(AIProvider.allCases) { p in
                            Text(providerName(p)).tag(p)
                        }
                    }
                    .labelsHidden()
                    .frame(width: SettingsMetrics.trailingColumn, alignment: .trailing)
                    .onChange(of: controller.provider) { _, _ in
                        controller.providerChanged()
                        // A fresh provider always starts on its own first preset (see
                        // AISettingsController.providerChanged), never a stranger's custom id.
                        isEditingCustomModel = false
                    }
                    .uiTestAnchor("settings.ai.provider")
                }

                SettingsRow(label: String(localized: "settings.ai.url")) {
                    KTextField("https://ghostcli.dev/v1", text: $controller.baseURLText)
                        .frame(width: SettingsMetrics.trailingColumn)
                        .disabled(controller.provider != .custom)
                        .onChange(of: controller.baseURLText) { _, _ in controller.markConfigChanged() }
                        .uiTestAnchor("settings.ai.url")
                }

                SettingsRow(label: String(localized: "settings.ai.model")) {
                    modelControl
                }

                SettingsRow(label: String(localized: "settings.ai.key")) {
                    keyControl
                }
                // Key status is a caption under the row, never squeezed next to the
                // buttons — a button label must never truncate, and this text can wrap.
                SettingsHelpRow {
                    Text(controller.hasKey ? String(localized: "settings.ai.key.saved") : String(localized: "settings.ai.key.none"))
                        .font(Typo.meta)
                        .foregroundStyle(Tok.textTertiary)
                    Spacer()
                }

                // Shown only when this app has no key of its own yet AND one already exists
                // under the old, pre-app-owned-store entry — an explicit action, not
                // automatic: pressing it is the one Keychain dialog the user sees, once, for
                // a key already typed in before this app-owned store existed.
                if controller.canAdoptLegacyKey {
                    SettingsHelpRow {
                        VStack(alignment: .leading, spacing: Space.x1) {
                            Text(String(localized: "settings.ai.key.adopt.note"))
                                .font(Typo.meta)
                                .foregroundStyle(Tok.textTertiary)
                            Button(String(localized: "settings.ai.key.adopt")) {
                                controller.adoptLegacyKey()
                            }
                            .kButton(.secondary, size: .compact)
                            .fixedSize()
                            .uiTestAnchor("settings.ai.key.adopt")
                        }
                        Spacer()
                    }
                }

                // Data-policy note and its value both read as body text that wraps, not a
                // one-line chip — the value can run long ("Unknown. Retention and logging
                // are not verified.") and must never truncate.
                VStack(alignment: .leading, spacing: Space.x1) {
                    Text(String(localized: "settings.ai.datapolicy.note"))
                        .font(Typo.meta)
                        .foregroundStyle(Tok.textTertiary)
                    // No red and no "!" in this app, so caution is carried by a glyph, not by colour.
                    HStack(alignment: .firstTextBaseline, spacing: Space.x2) {
                        Icon("shield", size: Metrics.iconS)
                            .foregroundStyle(Tok.textSecondary)
                            .accessibilityHidden(true)
                        Text(String(localized: "settings.ai.datapolicy.unknown"))
                            .font(Typo.meta)
                            .foregroundStyle(Tok.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                testSection
            }
        }
        .onAppear {
            // A model id saved before this control existed (or typed under "Other…" last
            // time) may not be one of the provider's own presets — open straight into the
            // text field instead of silently showing "Other…" selected over a blank-looking id.
            if !controller.provider.models.isEmpty && !controller.provider.models.contains(controller.modelID) {
                isEditingCustomModel = true
            }
        }
    }

    private var modeNote: String {
        switch controller.mode {
        case .off: return String(localized: "ai.mode.off.note")
        case .privateOnly: return String(localized: "ai.mode.private_only.note")
        case .allowAny: return String(localized: "ai.mode.allow_any.note")
        }
    }

    private func providerName(_ p: AIProvider) -> String {
        switch p {
        case .ghostCLI:   return String(localized: "settings.ai.provider.ghostcli")
        case .openRouter: return String(localized: "settings.ai.provider.openrouter")
        case .custom:     return String(localized: "settings.ai.provider.custom")
        }
    }

    /// Previously a text field AND a popup were both bound to the same value, redundantly.
    /// ONE control now: a preset provider shows a popup of its models plus "Other…"; picking
    /// "Other…" swaps it for a free-text field with a way back to the popup. `.custom` never
    /// had a model list, so it keeps the free-text field only. `controller.modelID` is still
    /// what Test reads either way.
    @ViewBuilder
    private var modelControl: some View {
        if controller.provider.models.isEmpty {
            KTextField(String(localized: "settings.ai.model"), text: $controller.modelID)
                .frame(width: SettingsMetrics.trailingColumn)
                .onChange(of: controller.modelID) { _, _ in controller.markConfigChanged() }
                .uiTestAnchor("settings.ai.model")
        } else if isEditingCustomModel {
            HStack(spacing: Space.x2) {
                Button {
                    isEditingCustomModel = false
                    if controller.modelID != controller.provider.models.first {
                        controller.modelID = controller.provider.models.first ?? ""
                        controller.markConfigChanged()
                    }
                } label: {
                    Icon("chevron-left", size: Metrics.iconS)
                }
                .kButton(.ghost, size: .compact)
                .accessibilityLabel(String(localized: "settings.ai.model.backtopresets"))
                .uiTestAnchor("settings.ai.model.backtopresets")
                KTextField(String(localized: "settings.ai.model"), text: $controller.modelID)
                    .frame(width: SettingsMetrics.trailingColumn)
                    .onChange(of: controller.modelID) { _, _ in controller.markConfigChanged() }
                    .uiTestAnchor("settings.ai.model")
            }
        } else {
            Picker(String(localized: "settings.ai.model"), selection: modelPickerSelection) {
                ForEach(controller.provider.models, id: \.self) { Text($0).tag($0) }
                Text(String(localized: "settings.ai.model.other")).tag(Self.otherSentinel)
            }
            .labelsHidden()
            .frame(width: SettingsMetrics.trailingColumn, alignment: .trailing)
            .uiTestAnchor("settings.ai.model")
        }
    }

    /// The picker's own sentinel case for "Other…" — never a real model id, so it can never
    /// collide with one a provider actually lists.
    private static let otherSentinel = "__other__"

    /// The popup always shows one of the provider's own model ids, so a custom id typed
    /// earlier (then abandoned by switching back to a preset without saving) never leaves it
    /// pointing at a tag with no matching row.
    private var modelPickerSelection: Binding<String> {
        Binding(
            get: { controller.provider.models.contains(controller.modelID) ? controller.modelID : Self.otherSentinel },
            set: { newValue in
                if newValue == Self.otherSentinel {
                    isEditingCustomModel = true
                } else {
                    controller.modelID = newValue
                    controller.markConfigChanged()
                }
            }
        )
    }

    @ViewBuilder
    private var keyControl: some View {
        if isEditingKey {
            HStack(spacing: Space.x2) {
                KTextField(String(localized: "settings.ai.key"), text: $keyInput)
                    .frame(width: 200)
                    .uiTestAnchor("settings.ai.key.input")
                Button(String(localized: "common.save")) {
                    controller.setKey(keyInput)
                    keyInput = ""
                    isEditingKey = false
                }
                .kButton(.secondary, size: .compact)
                .fixedSize()
                .disabled(keyInput.isEmpty)
                .uiTestAnchor("settings.ai.key.save")
                Button(String(localized: "common.cancel")) { isEditingKey = false; keyInput = "" }
                    .kButton(.ghost, size: .compact)
                    .fixedSize()
            }
        } else {
            HStack(spacing: Space.x2) {
                // A button label may never truncate — .fixedSize() forces its natural
                // width instead of letting the row's trailing column squeeze it.
                Button(controller.hasKey ? String(localized: "settings.ai.key.replace") : String(localized: "common.add")) {
                    isEditingKey = true
                }
                .kButton(.secondary, size: .compact)
                .fixedSize()
                .uiTestAnchor("settings.ai.key.edit")
                if controller.hasKey {
                    Button(String(localized: "common.delete")) { controller.removeKey() }
                        .kButton(.ghost, size: .compact)
                        .fixedSize()
                        .uiTestAnchor("settings.ai.key.delete")
                }
            }
        }
    }

    @ViewBuilder
    private var testSection: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            HStack {
                Button {
                    Task { await controller.runTest() }
                } label: {
                    if controller.isTesting {
                        HStack(spacing: Space.x2) {
                            ProgressView().controlSize(.small)
                            // Distinct from the idle label ("Test") so a call that runs for
                            // several seconds (measured live: 13-17s against GhostCLI) reads
                            // as in progress, not stuck.
                            Text(String(localized: "settings.ai.test.running"))
                        }
                    } else {
                        Text(String(localized: "settings.ai.test"))
                    }
                }
                .kButton(.secondary)
                .disabled(controller.isTesting)
                .uiTestAnchor("settings.ai.test")

                if let result = controller.lastTest {
                    testResultLabel(result)
                }
                Spacer()
            }

            HStack {
                Spacer()
                Button(String(localized: "common.save")) { controller.save() }
                    .kButton(.primary)
                    .disabled(!controller.testPassedForCurrentConfig)
                    .uiTestAnchor("settings.ai.save")
            }
        }
        .padding(.top, Space.x2)
    }

    private func testResultLabel(_ result: AISettingsTestResult) -> some View {
        HStack(spacing: Space.x2) {
            if result.ok {
                Text(String(format: String(localized: "settings.ai.test.ok.ms"), result.milliseconds))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textSecondary)
                if let served = result.servedBy {
                    KBadge(served)
                }
            } else {
                Text(String(localized: "settings.ai.test.fail"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textSecondary)
            }
        }
    }
}
