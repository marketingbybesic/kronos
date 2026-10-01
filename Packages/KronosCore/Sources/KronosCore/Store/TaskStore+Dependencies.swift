// Part of TaskStore. Task dependencies ("Waits on", w22e).
//
// A dependency is stored as ONE defaulted attribute on the dependant (`KTask.waitsOnIDs`).
// Blocked is DERIVED, never stored: a task is blocked while any task it waits on is still
// open. Completing the blocker therefore unblocks dependants with nothing to write, and the
// dependant keeps its own status (a blocked task is not `.waiting`; it is only skipped by
// the "next task" choosers: RankingEngine, OrdoEngine.current, the Now card).

import Foundation

@MainActor
extension TaskStore {

    /// True while any task this one waits on is open. A waited-on task that was deleted or
    /// purged does not block (it can never be completed, so blocking on it would be forever).
    public func isBlocked(_ id: UUID) -> Bool {
        guard let t = task(id) else { return false }
        return blockedIDs(in: [t]).contains(id)
    }

    /// Ids of every blocked task among `tasks` (default: every live task), one fetch.
    public func blockedIDs(in tasks: [KTask]? = nil) -> Set<UUID> {
        let all = allTasks()
        return DependencyGraph.blocked(in: tasks ?? all, lookup: all)
    }

    /// Replace what `id` waits on. Ids that are the task itself, unknown/deleted, duplicated or
    /// would close a cycle are DROPPED (a cycle would block every task in it forever, with no
    /// way to complete any of them). Returns true when every requested id was accepted.
    /// REGISTERS UNDO.
    @discardableResult
    public func setWaitsOn(_ id: UUID, _ ids: [UUID]) -> Bool {
        let (accepted, allOK) = acceptedWaitsOn(id, ids)
        update(id) { $0.waitsOnIDs = accepted.map(\.uuidString).joined(separator: ",") }
        return allOK
    }

    /// As `setWaitsOn`, with no undo step. NO UNDO: MCP `update_task`.
    @discardableResult
    public func setWaitsOnNoUndo(_ id: UUID, _ ids: [UUID]) -> Bool {
        let (accepted, allOK) = acceptedWaitsOn(id, ids)
        updateNoUndo(id) { $0.waitsOnIDs = accepted.map(\.uuidString).joined(separator: ",") }
        return allOK
    }

    /// True when making `id` wait on `other` would create a cycle (or is the task itself).
    public func wouldCreateCycle(_ id: UUID, waitingOn other: UUID) -> Bool {
        DependencyGraph.wouldCycle(id, waitingOn: other, edges: edgeMap(allTasks()))
    }

    private func edgeMap(_ tasks: [KTask]) -> [UUID: [UUID]] {
        var m: [UUID: [UUID]] = [:]
        for t in tasks where !t.waitsOnIDs.isEmpty { m[t.id] = t.waitsOn }
        return m
    }

    private func acceptedWaitsOn(_ id: UUID, _ ids: [UUID]) -> (accepted: [UUID], allOK: Bool) {
        let all = allTasks()
        let live = Set(all.map(\.id))
        var edges = edgeMap(all)
        edges[id] = []
        var accepted: [UUID] = []
        var allOK = true
        for other in ids {
            guard live.contains(other), !accepted.contains(other),
                  !DependencyGraph.wouldCycle(id, waitingOn: other, edges: edges) else {
                allOK = false
                continue
            }
            accepted.append(other)
            edges[id] = accepted
        }
        return (accepted, allOK)
    }
}

/// Pure graph helpers, shared by the store and by RankingEngine (which must stay fetch-free).
public enum DependencyGraph {

    /// Blocked ids among `tasks`; `lookup` is the pool used to decide whether a waited-on task
    /// is still open (an id absent from `lookup` counts as gone, so it does not block).
    public static func blocked(in tasks: [KTask], lookup: [KTask]) -> Set<UUID> {
        let open = Set(lookup.filter { KStatus.open.contains($0.status) }.map(\.id))
        var out = Set<UUID>()
        for t in tasks where !t.waitsOnIDs.isEmpty {
            if t.waitsOn.contains(where: { open.contains($0) }) { out.insert(t.id) }
        }
        return out
    }

    /// Would `id -> other` close a loop? True when `other == id` or `other` already reaches `id`.
    public static func wouldCycle(_ id: UUID, waitingOn other: UUID, edges: [UUID: [UUID]]) -> Bool {
        if other == id { return true }
        var seen = Set<UUID>()
        var stack = [other]
        while let cur = stack.popLast() {
            if cur == id { return true }
            guard seen.insert(cur).inserted else { continue }
            stack.append(contentsOf: edges[cur] ?? [])
        }
        return false
    }
}
