#if os(macOS)
// L4 — MCP. `review_status` (finish-round-1 B3): read-only. Reports, per task, the agent-verdict
// state (reviewRaw) and the person's separate "reviewed" phase-gate mark. The mark is NOT a KTask
// field (a schema change there breaks every already-persisted V2 store's entity-hash match — see
// SchemaV1Frozen.swift's header and ActivityLog.swift's `reviewed`/`unreviewed` doc comment):
// it is derived from the newest `task.reviewed`/`task.unreviewed` row per task in the device-local
// activity log (AgentHub/KActivity), the same log `approved`/`rejected` already ride in. No tool
// may set either mark: `reviewed`/`unreviewed` rows are appended only by the person's own UI
// (InspectorScreen.swift / TaskContextMenu.swift). `need(_:)` in MCPDispatcher+Scopes.swift maps
// this tool to `.read`, same as get_task — no write authorization path exists for it, so it is
// mechanically impossible for any scope, including write.all, to mutate state through this call.

import Foundation

extension MCPDispatcher {

    // MARK: - review_status

    struct ReviewStatusEntry: Encodable {
        let id: UUID
        /// "todo" or "done" (every closed KStatus collapses to "done" here; the caller already
        /// has `get_task`/`list_tasks` for the exact status).
        let state: String
        /// "none" | "pending" | "approved" | "rejected" — the agent-proposal verdict (reviewRaw).
        /// `awaitingCheck` (4, done by the agent, awaiting the person's check) reads as "pending":
        /// from the agent's side both mean "the person has not decided yet".
        let verdict: String
        let reviewedAt: Date?
        let reviewedBy: String?
    }

    private static func verdictName(_ raw: Int) -> String {
        switch raw {
        case ReviewState.pending, ReviewState.awaitingCheck: return "pending"
        case ReviewState.approved: return "approved"
        case ReviewState.rejected: return "rejected"
        default: return "none"
        }
    }

    /// The newest `reviewed`/`unreviewed` row's timestamp per task id, across every task named —
    /// one pass over the (device-local, not store-sized) activity log rather than one query per
    /// task. Empty when no hub is attached (the plain dispatcher the selftests and the app's own
    /// calls use outside an agent context still answers the tool; it just never saw a mark).
    private func latestReviewedMarks(for ids: Set<UUID>) -> [UUID: Date] {
        guard let hub else { return [:] }
        struct Latest { var seq: Int; var verb: String; var at: Date }
        var latest: [UUID: Latest] = [:]
        for row in hub.rows() {
            guard let taskID = row.taskID, ids.contains(taskID) else { continue }
            guard row.verb == ActivityVerb.reviewed || row.verb == ActivityVerb.unreviewed else { continue }
            if (latest[taskID]?.seq ?? -1) < row.seq {
                latest[taskID] = Latest(seq: row.seq, verb: row.verb, at: row.at)
            }
        }
        var result: [UUID: Date] = [:]
        for (taskID, l) in latest where l.verb == ActivityVerb.reviewed {
            result[taskID] = l.at
        }
        return result
    }

    private func entry(_ t: KTask, reviewedAt: Date?) -> ReviewStatusEntry {
        ReviewStatusEntry(id: t.id,
                          state: KStatus.closed.contains(t.status) ? "done" : "todo",
                          verdict: Self.verdictName(t.reviewRaw),
                          reviewedAt: reviewedAt,
                          reviewedBy: reviewedAt != nil ? "owner" : nil)
    }

    func reviewStatus(_ arguments: Data) -> MCPToolOutcome {
        let params: MCPParams.ReviewStatus
        do { params = try decodeParams(MCPParams.ReviewStatus.self, arguments, tool: "review_status") } catch { return MCPToolOutcome.from(error) }
        if let v = params.validationError {
            return .error(v, message: "pass ids (1-200) or project, never both and never neither")
        }

        let tasks: [KTask]
        if let ids = params.ids {
            var found: [KTask] = []
            for id in ids {
                guard let t = store.task(id) else {
                    return .error(.notFound, message: "no task \(id)", data: ["id": id.uuidString])
                }
                found.append(t)
            }
            tasks = found
        } else if let project = params.project {
            guard store.allProjects(includeArchived: true).contains(where: { $0.id == project }) else {
                return .error(.notFound, message: "no project \(project)", data: ["project": project.uuidString])
            }
            tasks = store.allTasksIncludingSubtasks().filter { $0.projectID == project }
        } else {
            tasks = []  // unreachable: validationError already refused this shape
        }

        let marks = latestReviewedMarks(for: Set(tasks.map(\.id)))
        struct Result: Encodable { let tasks: [ReviewStatusEntry]; let total: Int }
        return .ok(Result(tasks: tasks.map { entry($0, reviewedAt: marks[$0.id]) }, total: tasks.count))
    }
}
#endif
