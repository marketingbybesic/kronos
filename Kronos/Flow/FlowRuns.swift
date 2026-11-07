// Kronos/Flow/FlowRuns.swift
// Flow's own handle onto the Phase 2 run contract store (RunStore, slice A) — built the same
// way every other local-store reader in this app target builds its own handle (ReviewedMarkHub,
// AgentsSettingsController: `try? AgentHub(directory: KronosStore.containerDirectory())`), and
// reused across every Flow file instead of opening a second `AgentHub`. If the runs store cannot
// be opened, every call degrades to "no run data" (a nil `RunStore`) rather than crashing Flow.
//
// `FlowAgentState` is Flow's own minimal copy of the plan's C1 status-glyph precedence (running >
// ready for review > failed > stale > delegated), built independently here because slice C's own
// `Kronos/List/ListRowView+AgentStatus.swift` glyph is not merged into this worktree yet — same
// icon choices, same wording, so the orchestrator can fold the two into one shared type at merge
// without a visible behaviour change either way.
import Foundation
import KronosCore

@MainActor
enum FlowRuns {
    private static var cached: RunStore?

    /// Lazily built once per process, then reused forever (matching `ReviewedMarkHub`'s own
    /// "build once, never rebuild" shape). `taskStore` is only read on the very first call.
    static func store(_ taskStore: any TaskStoring) -> RunStore? {
        if let cached { return cached }
        guard let hub = ReviewedMarkHub.shared else { return nil }
        let made = try? RunStore(directory: KronosStore.containerDirectory(), store: taskStore, hub: hub)
        cached = made
        return made
    }
}

/// The one status a Flow card's glyph shows for a task's agent activity.
enum FlowAgentState: Equatable {
    case running(agentName: String)
    case readyForReview(agentName: String)
    case failed(agentName: String)
    case stale(agentName: String)
    case delegated(agentName: String)
    case none

    /// `runStore` may be nil (the runs store failed to open) — a task then only ever reads as
    /// `.readyForReview`/`.delegated`/`.none`, the three states derived from the task's own
    /// fields rather than a run row.
    @MainActor static func of(_ task: KTask, runStore: RunStore?) -> FlowAgentState {
        let name = FlowAgentName.of(task)
        if let runStore {
            if runStore.activeRun(taskID: task.id) != nil { return .running(agentName: name) }
            if task.reviewRaw == ReviewState.awaitingCheck { return .readyForReview(agentName: name) }
            if let latest = runStore.runs(taskID: task.id).first {
                if latest.stateRaw == "failed" { return .failed(agentName: name) }
                if latest.stateRaw == "expired" { return .stale(agentName: name) }
            }
        } else if task.reviewRaw == ReviewState.awaitingCheck {
            return .readyForReview(agentName: name)
        }
        if task.assigneeRaw == 1, task.agentID != nil,
           task.reviewRaw != ReviewState.approved, task.reviewRaw != ReviewState.awaitingCheck {
            return .delegated(agentName: name)
        }
        return .none
    }

    /// "cpu" and "arrowshape.turn.up.right" are registered Icon.swift map entries already used
    /// elsewhere for these same two states; the other three are raw SF Symbol names (contain a
    /// dot, so `Icon` resolves them directly without a map entry — Icon.swift's own rule).
    var iconName: String? {
        switch self {
        case .running: return "cpu"
        case .readyForReview: return "checkmark.seal"
        case .failed: return "exclamationmark.circle"
        case .stale: return "clock.badge.exclamationmark"
        case .delegated: return "arrowshape.turn.up.right"
        case .none: return nil
        }
    }

    /// Tooltip + accessibility label text, nil for `.none` (no glyph, nothing to say).
    var statusText: String? {
        switch self {
        case .running(let n): return String(format: String(localized: "flow.status.running"), n)
        case .readyForReview: return String(localized: "flow.status.readyforreview")
        case .failed(let n): return String(format: String(localized: "flow.status.failed"), n)
        case .stale(let n): return String(format: String(localized: "flow.status.stale"), n)
        case .delegated(let n): return String(format: String(localized: "list.row.delegated"), n)
        case .none: return nil
        }
    }

    var isRunning: Bool { if case .running = self { return true }; return false }
}

enum FlowAgentName {
    /// Same source `ListRowView+AgentStatus.swift`'s own glyphs use: `InspectorSourceLabel`'s
    /// agent-kind name, falling back to the generic "agent" string when none is resolvable.
    static func of(_ task: KTask) -> String {
        switch InspectorSourceLabel.kind(source: task.source, hasAgentID: task.agentID != nil) {
        case .agent(let n): return n
        case .generic, .none: return String(localized: "review.agent.unnamed")
        }
    }
}
