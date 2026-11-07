// Kronos/List/RunLaunching.swift
// Kronos v1.2 Phase 2 slice C's seam into slice B's harness launcher. `AppModel.runLauncher`
// defaults to `NoHarnessRunLauncher` below until `MCPAppBinding.attach` points it at the real
// `SupervisorRunLauncher` (Kronos/Runs/SupervisorRunLauncher.swift) — with no harness launcher
// live, "Hand off and run" (⇧H, the matching context-menu item, and the inspector's "Run again")
// stays visibly INERT (a clear refusal pill naming the reason) rather than doing nothing.
// handoff-ui slice: `launch` gained `model`, the harness's `--model`/`-m` value for this one run
// (nil/blank = Auto, the harness's own default). The protocol requirement takes it explicitly;
// the extension below restores the no-model convenience every pre-existing call site used
// (protocols cannot declare a default argument value on the requirement itself).
import Foundation
import KronosCore

/// Whether `agentID` can be launched right now, and why not when it can't — the "why" is shown
/// verbatim on the refusal pill, so it must already be a localized, user-facing sentence.
public enum RunLaunchAvailability: Equatable {
    case available
    case unavailable(reason: String)
}

/// How "Hand off and run" (and the inspector's "Run again") reach the harness launcher, without
/// slice C depending on slice B's concrete `RunSupervisor` type.
@MainActor
public protocol RunLaunching: AnyObject {
    func canLaunch(agentID: UUID) -> RunLaunchAvailability
    /// Starts the harness for `agentID` on `taskID` (the run itself is started by the launcher,
    /// same as `RunStore.start(launchedByKronos: true)` — slice C never calls `RunStore.start`
    /// directly for a launched run). Throws only for a store-level failure; a harness refusal is
    /// always reported through `canLaunch` BEFORE this is ever called, never here. `model` is
    /// this one run's chosen model, nil/blank for Auto (`HarnessArgv.substituting`).
    func launch(taskID: UUID, agentID: UUID, model: String?) throws
}

public extension RunLaunching {
    /// Convenience for a caller with no model choice to offer (Auto).
    func launch(taskID: UUID, agentID: UUID) throws {
        try launch(taskID: taskID, agentID: agentID, model: nil)
    }
}

/// Fallback whenever no harness launcher is live (app start, or the MCP server detached): every
/// agent reports no harness, so "Hand off and run" stays visible but inert with a clear reason
/// rather than silently doing nothing.
@MainActor
public final class NoHarnessRunLauncher: RunLaunching {
    public init() {}
    public func canLaunch(agentID: UUID) -> RunLaunchAvailability {
        .unavailable(reason: String(localized: "run.launch.noharness"))
    }
    public func launch(taskID: UUID, agentID: UUID, model: String?) throws {}
}

/// The display name of a run's own agent, resolved live from the device-local agent registry
/// (`ReviewedMarkHub`, InspectorScreen.swift) rather than `task.source` — a run's `agentSlug` is
/// who is ACTUALLY working the task right now, which can differ from how the task originated.
/// Falls back to the raw slug when the agent is no longer registered.
@MainActor
enum RunAgentNaming {
    static func displayName(forSlug slug: String) -> String {
        ReviewedMarkHub.shared?.agent(slug: slug)?.displayName ?? slug
    }
}

/// Per-agent "last used model" (preselected the next time a model picker opens for that agent)
/// plus a small shared "recently typed" list (most-recent-first, capped) so a model name typed
/// once does not need retyping in the inspector's hand-off section or the list's H/⇧H model row.
/// Device-local UI memory only (`KronosEnv.defaults`): never synced, never part of the run
/// contract — a run's own model choice is carried as an argv flag only, never stored on
/// `KAgentRun` (handoff-ui slice).
@MainActor
enum HandoffModelPrefs {
    private static let recentKey = "kronos.handoff.recentModels"
    private static let recentCap = 6

    private static func lastUsedKey(agentID: UUID) -> String { "kronos.handoff.lastModel.\(agentID.uuidString)" }

    static func lastUsed(agentID: UUID) -> String? {
        KronosEnv.defaults.string(forKey: lastUsedKey(agentID: agentID))
    }

    static func recent() -> [String] {
        KronosEnv.defaults.stringArray(forKey: recentKey) ?? []
    }

    /// Records `model` as `agentID`'s last choice and bumps it to the front of the shared recent
    /// list (deduplicated, capped). A blank model is "Auto" and clears the per-agent memory
    /// instead — Auto needs no model name to remember.
    static func record(_ model: String, agentID: UUID) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            KronosEnv.defaults.removeObject(forKey: lastUsedKey(agentID: agentID))
            return
        }
        KronosEnv.defaults.set(trimmed, forKey: lastUsedKey(agentID: agentID))
        var list = recent().filter { $0 != trimmed }
        list.insert(trimmed, at: 0)
        KronosEnv.defaults.set(Array(list.prefix(recentCap)), forKey: recentKey)
    }
}
