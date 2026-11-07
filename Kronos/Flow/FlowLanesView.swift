// Kronos/Flow/FlowLanesView.swift
// E4: the "L" key's alternate rendering — the same visible card set as the columns view,
// regrouped into one horizontal lane per agent instead of by dependency depth. The person's own
// lane (unassigned/not-yet-delegated cards) always shows first; an agent gets a lane only while
// it actually has a card here (an active run, or a delegation not yet picked up).
import SwiftUI
import KronosCore

struct FlowLanesView: View {
    struct Lane: Identifiable {
        let id: UUID
        let title: String
        let cards: [UUID]
    }

    @Bindable var model: AppModel
    let tasksByID: [UUID: KTask]
    let visibleIDs: [UUID]
    let runStore: RunStore?
    let focusedID: UUID?
    let highlighted: Set<UUID>
    /// Plan F's "Milestones" gate mark (FlowScreen.FlowContext.gateIDs) — >= 2 open dependents.
    let gateIDs: Set<UUID>
    let onSelect: (UUID) -> Void

    private static let ownerLaneID = UUID(uuidString: "00000000-0000-0000-0000-00000000DA10")!   // RunStore's own person id

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Space.x4) {
                laneSection(ownerLane)
                if agentLanes.isEmpty {
                    Text(String(localized: "flow.lane.empty"))
                        .font(Typo.meta)
                        .foregroundStyle(Tok.textTertiary)
                        .padding(.leading, Space.x2)
                } else {
                    ForEach(agentLanes) { laneSection($0) }
                }
            }
            .padding(Space.x3)
        }
    }

    private func laneSection(_ lane: Lane) -> some View {
        VStack(alignment: .leading, spacing: Space.x1) {
            Text("\(lane.title) · \(lane.cards.count)")
                .font(Typo.sectionHdr)
                .foregroundStyle(Tok.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Metrics.flowCardGap) {
                    ForEach(lane.cards, id: \.self) { id in
                        if let task = tasksByID[id] {
                            FlowCardView(model: model, task: task, isFocused: id == focusedID,
                                        isDimmed: !highlighted.isEmpty && !highlighted.contains(id),
                                        isGate: gateIDs.contains(id), runStore: runStore, onSelect: { onSelect(id) })
                        }
                    }
                }
            }
        }
    }

    /// The agent id a card's lane is keyed by — the agent actively running it, else the agent
    /// it is delegated to, else nil (the person's own lane).
    private func laneAgentID(_ task: KTask) -> UUID? {
        if let run = runStore?.activeRun(taskID: task.id) { return run.agentID }
        if task.assigneeRaw == 1, let agentID = task.agentID { return agentID }
        return nil
    }

    private var ownerLane: Lane {
        let cards = visibleIDs.filter { id in
            guard let t = tasksByID[id] else { return false }
            return laneAgentID(t) == nil
        }
        return Lane(id: Self.ownerLaneID, title: String(localized: "flow.lane.owner"), cards: cards)
    }

    /// Alex first (above), then every registered enabled agent that actually has a card here —
    /// in `TaskDelegation.enabledAgents()`'s own (registration) order, same source Settings and
    /// the row's "Delegate to…" submenu already read.
    private var agentLanes: [Lane] {
        TaskDelegation.enabledAgents().compactMap { agent in
            let cards = visibleIDs.filter { id in
                guard let t = tasksByID[id] else { return false }
                return laneAgentID(t) == agent.id
            }
            guard !cards.isEmpty else { return nil }
            return Lane(id: agent.id, title: agent.displayName, cards: cards)
        }
    }
}
