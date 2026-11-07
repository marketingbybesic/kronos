// Kronos/Detail/InspectorHandoffSection.swift
// Below InspectorRunSection (person-feedback round, handoff-ui slice): the inspector's own full
// hand-off control. Pick an agent (last-used preselected — the same shared preference
// ListHandoffPick's H/⇧H popover reads and writes, so the two surfaces never disagree on "who
// did I hand off to last"), pick a model (free text, "Auto" when blank, a small menu of
// recently used values, remembered per agent), then either "Hand off" (delegate only, the same
// TaskDelegation.delegate write the row's menu makes) or "Hand off and run" (the same
// RunLaunching seam ⇧H and the row's context menu use, disabled with the same refusal reason
// when the agent has no pinned harness). Shown only while at least one agent is registered.
// InspectorScreen's own compact delegateControl() (inside Details) is untouched by this slice —
// that stays the quick one-click menu; this is the full control with a model choice.
import SwiftUI
import KronosCore

struct InspectorHandoffSection: View {
    let model: AppModel
    let task: KTask

    @State private var selectedAgentID: UUID?
    @State private var modelText = ""

    private var agents: [KAgent] { TaskDelegation.enabledAgents() }
    private var currentAgent: KAgent? {
        agents.first { $0.id == selectedAgentID } ?? agents.first
    }

    var body: some View {
        if !agents.isEmpty, let agent = currentAgent {
            content(agent)
                .onAppear(perform: loadDefaults)
        }
    }

    private func content(_ agent: KAgent) -> some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            InspectorSectionCaption(String(localized: "detail.handoff.title"))
            KPropertyList {
                KPropertyRow(String(localized: "detail.handoff.agent.label")) { agentMenu(agent) }
                    .accessibilityLabel(String(localized: "detail.handoff.agent.label"))
                    .accessibilityValue(agent.displayName)
                KPropertyRow(String(localized: "detail.handoff.model.label")) { modelField }
            }
            actions(agent)
        }
        .padding(.vertical, Space.x2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .uiTestAnchor("inspector.handoff")
    }

    private func agentMenu(_ agent: KAgent) -> some View {
        InspectorValueMenu(text: agent.displayName) {
            ForEach(agents, id: \.id) { candidate in
                Button {
                    selectedAgentID = candidate.id
                    modelText = HandoffModelPrefs.lastUsed(agentID: candidate.id) ?? ""
                } label: {
                    if candidate.id == agent.id {
                        Label(candidate.displayName, systemImage: "checkmark")
                    } else {
                        Text(candidate.displayName)
                    }
                }
            }
        }
        .uiTestAnchor("inspector.handoff.agent")
    }

    private var modelField: some View {
        HStack(spacing: Space.x1) {
            KTextField(String(localized: "detail.handoff.model.auto"), text: $modelText)
                .uiTestAnchor("inspector.handoff.model")
            let recentModels = HandoffModelPrefs.recent()
            if !recentModels.isEmpty {
                Menu {
                    ForEach(recentModels, id: \.self) { value in
                        Button(value) { modelText = value }
                    }
                } label: {
                    Icon("chevron-down", size: Metrics.iconXS).foregroundStyle(Tok.textTertiary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel(String(localized: "detail.handoff.model.recent"))
                .uiTestAnchor("inspector.handoff.model.recent")
            }
        }
    }

    /// Disables "Hand off and run" with the live `canLaunch` reason — the same `agents.harness.
    /// unpinned`/`.changed`/`run.launch.noharness` text ⇧H already shows as a pill — rather than
    /// letting the click fail silently-ish after the fact. A refusal `canLaunch` cannot see (the
    /// concurrency cap, a claim raced in by another agent) still surfaces as that same pill,
    /// through `HandoffAndRun.attempt` → `SupervisorRunLauncher.launch`, unchanged.
    private func actions(_ agent: KAgent) -> some View {
        let refusal: String? = {
            if case .unavailable(let reason) = model.runLauncher.canLaunch(agentID: agent.id) { return reason }
            return nil
        }()
        return HStack(spacing: Space.x2) {
            Button(String(localized: "detail.handoff.go")) { handoff(agent) }
                .kButton(.secondary, size: .compact)
                .uiTestAnchor("inspector.handoff.go")
            Button(String(localized: "list.handoff.titlerun")) { handoffAndRun(agent) }
                .kButton(.primary, size: .compact)
                .disabled(refusal != nil)
                .opacity(refusal != nil ? 0.4 : 1)
                .kTooltip(refusal ?? String(localized: "detail.handoff.gorun.help"))
                .uiTestAnchor("inspector.handoff.gorun")
            Spacer(minLength: 0)
        }
    }

    private func loadDefaults() {
        guard selectedAgentID == nil else { return }
        let preferred = ListHandoffPick.lastUsedSlug.flatMap { slug in agents.first { $0.slug == slug } } ?? agents.first
        guard let preferred else { return }
        selectedAgentID = preferred.id
        modelText = HandoffModelPrefs.lastUsed(agentID: preferred.id) ?? ""
    }

    private func handoff(_ agent: KAgent) {
        ListHandoffPick.lastUsedSlug = agent.slug
        TaskDelegation.delegate(task.id, to: agent, model: model)
    }

    private func handoffAndRun(_ agent: KAgent) {
        ListHandoffPick.lastUsedSlug = agent.slug
        let trimmedModel = modelText.trimmingCharacters(in: .whitespacesAndNewlines)
        HandoffModelPrefs.record(trimmedModel, agentID: agent.id)
        HandoffAndRun.attempt([task.id], to: agent, model: model, aiModel: trimmedModel.isEmpty ? nil : trimmedModel)
    }
}
