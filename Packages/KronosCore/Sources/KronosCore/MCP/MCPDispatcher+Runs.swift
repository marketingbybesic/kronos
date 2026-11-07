#if os(macOS)
// MCP. run_start, run_update, run_finish — the agent side of the run contract (Kronos v1.2,
// Phase 1 slice A4). RunStore does the real work; these handlers decode params, map RunStore's
// errors onto an MCPToolError with a message that tells the agent what to do next, and shape the
// reply JSON. Same wiring as comment_task (MCPDispatcher+Agents.swift): decodeParams, call the
// store, .ok/.error.

import Foundation

extension MCPDispatcher {

    private var noRunsMessage: String {
        "runs are not set up on this Kronos right now (not a token problem); use comment_task to report progress and complete_task to finish"
    }

    // MARK: - run_start

    func runStart(_ arguments: Data) -> MCPToolOutcome {
        let params: MCPParams.RunStart
        do { params = try decodeParams(MCPParams.RunStart.self, arguments, tool: "run_start") } catch { return MCPToolOutcome.from(error) }
        if let lease = params.leaseSeconds, !(60...7200).contains(lease) {
            return .error(.invalidParams, message: "leaseSeconds must be 60-7200", data: ["field": "leaseSeconds"])
        }
        guard let runs else { return .error(.invalidState, message: noRunsMessage) }
        do {
            let run = try runs.start(taskID: params.taskID, agent: identity, launchedByKronos: false,
                                     lease: TimeInterval(params.leaseSeconds ?? 1800))
            struct Result: Encodable { let runID: UUID; let leaseUntil: Date }
            return .ok(Result(runID: run.id, leaseUntil: run.leaseUntil))
        } catch { return mapRunError(error, taskID: params.taskID) }
    }

    // MARK: - run_update

    func runUpdate(_ arguments: Data) -> MCPToolOutcome {
        let params: MCPParams.RunUpdate
        do { params = try decodeParams(MCPParams.RunUpdate.self, arguments, tool: "run_update") } catch { return MCPToolOutcome.from(error) }
        if let artifacts = params.artifactsAdd, artifacts.count > 20 {
            return .error(.invalidParams, message: "artifactsAdd holds \(artifacts.count) entries; the limit is 20", data: ["field": "artifactsAdd"])
        }
        guard let runs else { return .error(.invalidState, message: noRunsMessage) }
        do {
            try runs.update(runID: params.runID, agent: identity, progress: params.progress, note: params.note,
                            artifactsAdd: params.artifactsAdd ?? [])
            guard let run = runs.run(id: params.runID) else {
                return .error(.internalError, message: "run vanished during update")
            }
            struct Result: Encodable { let leaseUntil: Date }
            return .ok(Result(leaseUntil: run.leaseUntil))
        } catch { return mapRunError(error, runID: params.runID) }
    }

    // MARK: - run_finish

    func runFinish(_ arguments: Data) -> MCPToolOutcome {
        let params: MCPParams.RunFinish
        do { params = try decodeParams(MCPParams.RunFinish.self, arguments, tool: "run_finish") } catch { return MCPToolOutcome.from(error) }
        guard let outcome = RunOutcome(rawValue: params.outcome) else {
            return .error(.invalidParams, message: "outcome must be done, failed or handoff", data: ["field": "outcome"])
        }
        guard (1...2000).contains(params.summary.count) else {
            return .error(.invalidParams, message: "summary must be 1-2000 characters", data: ["field": "summary"])
        }
        if let artifacts = params.artifactsAdd, artifacts.count > 20 {
            return .error(.invalidParams, message: "artifactsAdd holds \(artifacts.count) entries; the limit is 20", data: ["field": "artifactsAdd"])
        }
        if outcome == .handoff, (params.handoffTo ?? "").isEmpty {
            return .error(.invalidParams, message: "handoff needs handoffTo", data: ["field": "handoffTo"])
        }
        guard let runs else { return .error(.invalidState, message: noRunsMessage) }
        do {
            try runs.finish(runID: params.runID, agent: identity, outcome: outcome, summary: params.summary,
                            artifactsAdd: params.artifactsAdd ?? [], handoffTo: params.handoffTo)
            struct Result: Encodable { let state: String }
            return .ok(Result(state: outcome.rawValue))
        } catch { return mapRunError(error, runID: params.runID) }
    }

    // MARK: - error mapping

    private func mapRunError(_ error: Error, taskID: UUID? = nil, runID: UUID? = nil) -> MCPToolOutcome {
        guard let e = error as? RunError else { return .error(.internalError, message: "\(error)") }
        let iso = ISO8601DateFormatter()
        switch e {
        case .claimed(let by):
            let until = taskID.flatMap { runs?.activeRun(taskID: $0) }.map { iso.string(from: $0.leaseUntil) } ?? "soon"
            return .error(.conflict, message: "claimed: \(by) is running this task until \(until)", data: ["agent": by])
        case .taskPending:
            return .error(.invalidState, message: "pending: the owner has not approved this task yet")
        case .taskMissing:
            return .error(.notFound, message: "no task \(taskID.map(\.uuidString) ?? "")")
        case .taskDone:
            return .error(.invalidState, message: "task is already done")
        case .notYours:
            let owner = runID.flatMap { runs?.run(id: $0) }?.agentSlug ?? "another agent"
            return .error(.forbidden, message: "not yours: run \(runID.map(\.uuidString) ?? "") belongs to \(owner)", data: ["agent": owner])
        case .notActive:
            return .error(.invalidState, message: "that run is not active; start a new one")
        case .unknownAgent:
            return .error(.notFound, message: "no agent with that slug")
        case .badArtifact(let kind):
            return .error(.invalidParams, message: "artifact kind must be file, diff, commit, pr or url, got \(kind)",
                         data: ["field": "artifactsAdd", "kind": kind])
        }
    }
}
#endif
