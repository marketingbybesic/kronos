// Kronos/List/ListHandoffPick.swift
// H / ⇧H (Kronos v1.2 Phase 2 slice C3): the agent-picker overlay, hosted by TaskListScreen like
// the row's own "P" project picker (ListProjectPick.swift), but keyed off `AppModel.
// handoffRequest` rather than per-row `@State` so it is one popover regardless of how many rows
// (1 or a whole multi-selection) asked for it. Arrow keys move the highlight (last-used agent
// preselected), Return picks it, Esc cancels with no change — same keys `ProjectPicker` answers.
import SwiftUI
import KronosCore

/// Pending agent pick: which tasks, and whether choosing an agent should also launch its
/// harness. `Identifiable` for `.popover(item:)` — a fresh request (new `id`) always replaces
/// whatever was showing rather than being mistaken for the same one.
struct HandoffRequest: Identifiable, Equatable {
    let id = UUID()
    let taskIDs: [UUID]
    let andRun: Bool
}

/// "Hand off and run": checks the launcher BEFORE writing anything (an agent with no harness
/// never half-delegates), then delegates and launches every task. Shared by the context menu's
/// "Hand off and run ▸" (TaskContextMenu.swift) and this picker's `andRun` path.
@MainActor
enum HandoffAndRun {
    static func attempt(_ ids: [UUID], to agent: KAgent, model: AppModel, aiModel: String? = nil) {
        switch model.runLauncher.canLaunch(agentID: agent.id) {
        case .unavailable(let reason):
            UndoToastCenter.shared.showNotice(reason)
        case .available:
            TaskDelegation.handoff(ids, to: agent, model: model)
            for id in ids { try? model.runLauncher.launch(taskID: id, agentID: agent.id, model: aiModel) }
        }
    }
}

struct ListHandoffPick: View {
    let model: AppModel
    let request: HandoffRequest
    let close: () -> Void

    @State private var highlighted: UUID?
    /// Only read/written when `request.andRun` (compact model row, handoff-ui slice).
    @State private var modelText = ""

    private var agents: [KAgent] { TaskDelegation.enabledAgents() }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x1) {
            Text(String(localized: request.andRun ? "list.handoff.titlerun" : "list.handoff.title"))
                .font(Typo.metaStrong)
                .foregroundStyle(Tok.textSecondary)
                .padding(.bottom, Space.x1)
            if agents.isEmpty {
                Text(String(localized: "detail.help.delegate.none"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(agents, id: \.id) { agent in row(agent) }
                modelRow
            }
        }
        .padding(Space.x3)
        .frame(width: 240)
        .background(Tok.overlay)
        .onAppear {
            let ids = agents.map(\.id)
            let preselected = Self.lastUsedSlug.flatMap { slug in agents.first { $0.slug == slug } }
            highlighted = preselected?.id ?? ids.first
            if request.andRun, let agentID = (preselected ?? agents.first)?.id {
                modelText = HandoffModelPrefs.lastUsed(agentID: agentID) ?? ""
            }
        }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.return) { confirmHighlighted(); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
        .uiTestAnchor("list.handoff.picker")
    }

    private func row(_ agent: KAgent) -> some View {
        Button {
            pick(agent)
        } label: {
            HStack(spacing: Space.x2) {
                Text(agent.displayName)
                Spacer(minLength: 0)
            }
            .font(Typo.row)
            .foregroundStyle(Tok.textPrimary)
            .frame(height: Metrics.minHit)
            .padding(.horizontal, Space.x2)
            .background(highlighted == agent.id ? Tok.hoverFill : .clear)
            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .uiTestAnchor("list.handoff.agent." + agent.slug)
    }

    private func move(_ delta: Int) {
        let ids = agents.map(\.id)
        guard !ids.isEmpty else { return }
        let i = highlighted.flatMap { ids.firstIndex(of: $0) } ?? 0
        highlighted = ids[(i + delta + ids.count) % ids.count]
    }

    private func confirmHighlighted() {
        guard let id = highlighted, let agent = agents.first(where: { $0.id == id }) else { close(); return }
        pick(agent)
    }

    private func pick(_ agent: KAgent) {
        close()
        Self.lastUsedSlug = agent.slug
        if request.andRun {
            let trimmedModel = modelText.trimmingCharacters(in: .whitespacesAndNewlines)
            HandoffModelPrefs.record(trimmedModel, agentID: agent.id)
            HandoffAndRun.attempt(request.taskIDs, to: agent, model: model, aiModel: trimmedModel.isEmpty ? nil : trimmedModel)
        } else {
            TaskDelegation.handoff(request.taskIDs, to: agent, model: model)
        }
    }

    /// Compact model row (handoff-ui slice): free text, "Auto" placeholder, a small menu of
    /// recently used values. Shown only in and-run mode — plain hand-off never launches a
    /// harness, so there is no flag for a model to ever reach.
    @ViewBuilder
    private var modelRow: some View {
        if request.andRun {
            HStack(spacing: Space.x1) {
                KTextField(String(localized: "detail.handoff.model.auto"), text: $modelText)
                    .uiTestAnchor("list.handoff.model")
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
                    .uiTestAnchor("list.handoff.model.recent")
                }
            }
            .padding(.top, Space.x1)
        }
    }

    static let lastUsedKey = "kronos.handoff.lastAgentSlug"
    static var lastUsedSlug: String? {
        get { KronosEnv.defaults.string(forKey: lastUsedKey) }
        set { KronosEnv.defaults.set(newValue, forKey: lastUsedKey) }
    }
}
