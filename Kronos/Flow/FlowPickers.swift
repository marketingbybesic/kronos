// Kronos/Flow/FlowPickers.swift
// The two small popovers Flow's keyboard opens (E5): W draws a dependency, H/⇧H hands a task to
// an agent. Both are Flow's own minimal copies of an existing pattern rather than imports of it:
// the waits-on picker mirrors `Kronos/Detail/InspectorWaitsOnRow.swift`'s `pickerContent` (a
// one-off private computed property there, not a reusable type) using the exact same Core calls
// (`waitsOnCandidates`, `setWaitsOn(_:_:editBase:)`); the hand-off picker calls the existing,
// already-shared `TaskDelegation.delegate`/`enabledAgents()` (Kronos/List/TaskContextMenu.swift)
// directly — the same write the list row's own "Delegate to…" submenu makes, so the two can
// never drift.
import SwiftUI
import KronosCore

/// W: search-and-pick what the given task waits on. Chips above a type-ahead list, same shape
/// as the inspector's own row.
struct FlowWaitsOnPicker: View {
    @Bindable var model: AppModel
    let task: KTask
    let onClose: () -> Void

    @State private var query = ""
    /// What the task waited on when the picker opened — the conflict-safe merge base, exactly
    /// like `InspectorWaitsOnRow.pickerBase`.
    @State private var base: [UUID]

    init(model: AppModel, task: KTask, onClose: @escaping () -> Void) {
        self.model = model
        self.task = task
        self.onClose = onClose
        _base = State(initialValue: task.waitsOn)
    }

    private var chosen: [KTask] { task.waitsOn.compactMap { model.store.task($0) } }
    private var candidates: [KTask] { model.store.waitsOnCandidates(for: task.id, query: query, limit: 8) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            Text(String(format: String(localized: "flow.waitson.picker.title"), task.title))
                .font(Typo.metaStrong)
                .foregroundStyle(Tok.textSecondary)
            if !chosen.isEmpty {
                InspectorFlowLayout(spacing: Space.x1) {
                    ForEach(chosen) { other in
                        KChip(other.waitsOnDisplayName, trailing: .clear, onTap: { remove(other.id) })
                    }
                }
            }
            KTextField(String(localized: "detail.waitson.search"), text: $query, autofocus: true)
            if candidates.isEmpty {
                Text(String(localized: "flow.waitson.picker.empty"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                    .padding(.vertical, Space.x1)
            } else {
                ForEach(candidates) { other in
                    Button { add(other.id) } label: {
                        Text(other.waitsOnDisplayName).font(Typo.row).foregroundStyle(Tok.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, Space.x1)
                    .uiTestAnchor("flow.waitson.candidate." + other.id.uuidString)
                }
            }
        }
        .padding(Space.x3)
        .frame(width: 280)
        .background(Tok.overlay)
        .onExitCommand(perform: onClose)
        .uiTestAnchor("flow.waitson.picker")
    }

    private func add(_ id: UUID) {
        var ids = task.waitsOn
        guard !ids.contains(id) else { return }
        ids.append(id)
        model.store.setWaitsOn(task.id, ids, editBase: base)
        model.didMutate()
        base = task.waitsOn
    }

    private func remove(_ id: UUID) {
        let ids = task.waitsOn.filter { $0 != id }
        model.store.setWaitsOn(task.id, ids, editBase: base)
        model.didMutate()
        base = task.waitsOn
    }
}

/// H / ⇧H: pick an agent to hand the focused task to. `launchesHarness` (⇧H) shows every row
/// disabled with "no harness configured" — nothing in this worktree can write a `KHarness` row
/// yet (Settings > Agents > Harness is slice B, Phase 2, not merged here), so this is always
/// accurately true today rather than a guess; the row still names the agent so the picker is
/// not empty while that lands.
struct FlowHandoffPicker: View {
    let task: KTask
    let model: AppModel
    let launchesHarness: Bool
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x1) {
            Text(String(format: String(localized: "flow.handoff.picker.title"), task.title))
                .font(Typo.metaStrong)
                .foregroundStyle(Tok.textSecondary)
                .padding(.bottom, Space.x1)
            let agents = TaskDelegation.enabledAgents()
            if agents.isEmpty {
                Text(String(localized: "flow.handoff.noagents"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
            } else {
                ForEach(agents) { agent in
                    row(agent)
                }
            }
        }
        .padding(Space.x3)
        .frame(width: 240)
        .background(Tok.overlay)
        .onExitCommand(perform: onClose)
    }

    private func row(_ agent: KAgent) -> some View {
        Button {
            guard !launchesHarness else { return }   // disabled row: see the header comment
            TaskDelegation.delegate(task.id, to: agent, model: model)
            onClose()
        } label: {
            HStack {
                Text(agent.displayName).font(Typo.row)
                Spacer(minLength: Space.x2)
                if launchesHarness {
                    Text(String(localized: "flow.handoff.noharness"))
                        .font(Typo.meta)
                        .foregroundStyle(Tok.textDisabled)
                }
            }
            .foregroundStyle(launchesHarness ? Tok.textDisabled : Tok.textPrimary)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Space.x1)
        .disabled(launchesHarness)
    }
}
