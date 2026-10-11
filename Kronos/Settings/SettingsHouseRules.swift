// Kronos/Settings/SettingsHouseRules.swift
// The "House rules" list in Settings > Coach: every rule the model prompts follow, with a switch
// per rule and a delete. Rules an agent proposes over MCP arrive switched off and wait here.
// Rules are managed in this list, not with Cmd-Z, so neither action registers an undo step; a
// delete asks for a second press instead.
import SwiftUI
import KronosCore

struct SettingsHouseRulesSection: View {
    let model: AppModel
    /// The rule whose Delete was pressed once; the second press deletes.
    @State private var confirmingDelete: UUID?
    /// The rule whose toggle was switched on while the 50-active cap (§6.5) was already full;
    /// waits here for the person to Replace or Cancel instead of silently failing or evicting.
    @State private var pendingActivate: UUID?

    var body: some View {
        // Reading the version re-renders the list after any store change (an agent adds a rule).
        let _ = model.version
        let rules = model.store.allRules(includeInactive: true)
        SettingsSection(title: String(localized: "settings.coach.section.houserules")) {
            SettingsHelpRow {
                Text(String(localized: "settings.coach.houserules.help"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if rules.isEmpty {
                SettingsEmptyRow(text: String(localized: "settings.planning.rules.empty"),
                                 anchor: "houserules.empty")
            } else {
                ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                    row(rule, index: index)
                }
            }
        }
        // A pending delete cancels itself, so a stray first press never lingers.
        .task(id: confirmingDelete) {
            guard confirmingDelete != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            confirmingDelete = nil
        }
        #if !RELEASE
        .onAppear { seedForSnapshot() }
        #endif
    }

    #if !RELEASE
    /// Snapshot runs only (`KRONOS_SNAPSHOT_HOUSERULES=1`, in-memory store): three rules so the
    /// list can be read at every text size and language, one of them long enough to wrap.
    private func seedForSnapshot() {
        let env = ProcessInfo.processInfo.environment
        guard KronosEnv.isSnapshot, env["KRONOS_SNAPSHOT_HOUSERULES"] != nil,
              model.store.allRules(includeInactive: true).isEmpty else { return }
        model.store.addAgentRule(text: "Tasks that mention the bank are people work, whatever else they say.",
                                 scope: .triage)
        model.store.addRule(text: "Keep every first move under sixty characters.", scope: .all, source: .manual)
        let third = model.store.addRule(text: "Put calls first when energy is high.", scope: .ordo, source: .feedback)
        model.store.setRuleActive(third.id, false)
        model.didMutate()
    }
    #endif

    private func row(_ rule: KRule, index: Int) -> some View {
        let isConfirmingDelete = confirmingDelete == rule.id
        return VStack(alignment: .leading, spacing: Space.x2) {
            HStack(alignment: .center, spacing: Space.x3) {
                VStack(alignment: .leading, spacing: Space.x1) {
                    Text(rule.text)
                        .font(Typo.row)
                        .foregroundStyle(rule.isActive ? Tok.textPrimary : Tok.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(String(format: String(localized: "settings.coach.houserules.meta"),
                                originText(rule), scopeText(rule.scope)))
                        .font(Typo.meta)
                        .foregroundStyle(Tok.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: Space.x2)
                Toggle(isOn: Binding(get: { rule.isActive }, set: { setActive(rule, $0) })) { EmptyView() }
                    .toggleStyle(.switch)
                    .tint(Tok.textPrimary)
                    .labelsHidden()
                    // The bare switch measures under 24 pt; pad its frame to the minimum hit
                    // target the a11y UI-test step enforces for every switch and Delete.
                    .frame(minWidth: Metrics.minHit, minHeight: Metrics.minHit)
                    .accessibilityLabel(String(format: String(localized: "settings.coach.houserules.toggle.a11y"), rule.text))
                    .uiTestAnchor("houserules.toggle.\(index)")
                RuleDeleteButton(isConfirming: isConfirmingDelete) { delete(rule) }
                .accessibilityLabel(String(format: String(localized: "settings.coach.houserules.delete.a11y"), rule.text))
                .uiTestAnchor("houserules.delete.\(index)")
            }
            .frame(maxWidth: .infinity, minHeight: Metrics.controlRegular, alignment: .leading)
            if pendingActivate == rule.id, let candidate = replaceCandidate(excluding: rule.id) {
                replaceConfirm(target: rule, candidate: candidate, index: index)
            }
        }
        .padding(.vertical, Space.x1)
        .uiTestAnchor("houserules.row.\(index)")
    }

    /// The active rule offered as a swap when the cap is full: `allRules` already sorts ascending
    /// by `createdAt` (then id), so the first active entry is also the oldest. There is no
    /// per-rule usage counter to rank by "least-used" (§6.5) without a `KRule` schema change
    /// (forbidden — it would break the persisted entity hash), so age is the next best proxy.
    private func replaceCandidate(excluding id: UUID) -> KRule? {
        model.store.allRules(includeInactive: true).first { $0.isActive && $0.id != id }
    }

    @ViewBuilder
    private func replaceConfirm(target: KRule, candidate: KRule, index: Int) -> some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            Text(String(format: String(localized: "settings.coach.houserules.full.confirm"), candidate.text))
                .font(Typo.meta)
                .foregroundStyle(Tok.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.x2) {
                Button(String(localized: "settings.coach.houserules.full.replace")) {
                    replace(target: target, candidate: candidate)
                }
                .kButton(.secondary, size: .compact)
                .uiTestAnchor("houserules.full.replace.\(index)")
                Button(String(localized: "common.cancel")) { pendingActivate = nil }
                    .kButton(.ghost, size: .compact)
                    .uiTestAnchor("houserules.full.cancel.\(index)")
                Spacer(minLength: 0)
            }
        }
    }

    private func setActive(_ rule: KRule, _ active: Bool) {
        if active, !rule.isActive, model.store.activeRuleCount() >= TaskStore.maxActiveRules {
            pendingActivate = rule.id
            return
        }
        pendingActivate = nil
        guard model.store.setRuleActive(rule.id, active) else { return }
        model.didMutate()
        AIWiring.refresh(model)
    }

    private func replace(target: KRule, candidate: KRule) {
        pendingActivate = nil
        guard model.store.setRuleActive(candidate.id, false) else { return }
        guard model.store.setRuleActive(target.id, true) else { return }
        model.didMutate()
        AIWiring.refresh(model)
    }

    private func delete(_ rule: KRule) {
        guard confirmingDelete == rule.id else { confirmingDelete = rule.id; return }
        confirmingDelete = nil
        guard model.store.deleteRule(rule.id) else { return }
        model.didMutate()
        AIWiring.refresh(model)
    }

    private func originText(_ rule: KRule) -> String {
        if rule.isFromAgent { return String(localized: "settings.coach.houserules.origin.agent") }
        switch rule.source {
        case .manual: return String(localized: "settings.coach.houserules.origin.you")
        case .agent: return String(localized: "settings.coach.houserules.origin.agent")
        case .feedback, .ordoProposal: return String(localized: "settings.coach.houserules.origin.correction")
        }
    }

    private func scopeText(_ scope: KRuleScope) -> String {
        switch scope {
        case .all: return String(localized: "settings.coach.houserules.scope.all")
        case .triage: return String(localized: "settings.coach.houserules.scope.triage")
        case .impuls: return String(localized: "settings.coach.houserules.scope.impuls")
        case .ordo: return String(localized: "settings.coach.houserules.scope.ordo")
        }
    }
}

/// A rule's Delete. A plain button is reachable by keyboard only under Full Keyboard Access; this one is
/// focusable on its own (Tab, then Space or Return) and shows the Kronos focus ring while it is.
private struct RuleDeleteButton: View {
    let isConfirming: Bool
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Text(isConfirming ? String(localized: "settings.coach.houserules.delete.confirm")
                              : String(localized: "settings.coach.houserules.delete"))
                .font(Typo.meta)
                .foregroundStyle(isConfirming ? Tok.textPrimary : Tok.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, Space.x2)
                .frame(minWidth: Metrics.minHit, minHeight: Metrics.controlCompact)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(true, interactions: .activate)
        .focused($isFocused)
        .focusEffectDisabled()
        .kFocusRing(isFocused, radius: Radius.control)
    }
}
