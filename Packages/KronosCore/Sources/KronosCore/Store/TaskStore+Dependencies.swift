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
        let all = allTasksIncludingSubtasks()
        return DependencyGraph.blocked(in: tasks ?? all, lookup: all)
    }

    // MARK: Finishing a blocked task
    //
    // `complete` stays unconditional (MCP, URL scheme, Intents and synced devices must never hang
    // on a prompt). The app's own completion paths ask `openBlockers` first and, when it is not
    // empty, offer the choices below. Each choice is ONE undo step.

    /// The tasks `id` waits on that are still open, in the order they are stored. A waited-on
    /// task that is done, canceled, deleted or gone does not count (same rule as `isBlocked`).
    public func openBlockers(of id: UUID) -> [KTask] {
        guard let t = task(id), !t.waitsOnIDs.isEmpty else { return [] }
        let byID = Dictionary(allTasksIncludingSubtasks().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<UUID>()
        return t.waitsOn.compactMap { other in
            guard seen.insert(other).inserted, let b = byID[other], KStatus.open.contains(b.status) else { return nil }
            return b
        }
    }

    /// True when "complete both" makes sense: `id` has open blockers and none of them is blocked
    /// itself (completing a blocker that is still waiting on something would just move the
    /// question one level down).
    public func canCompleteWithBlockers(_ id: UUID) -> Bool {
        let blockers = openBlockers(of: id)
        return !blockers.isEmpty && blockers.allSatisfy { openBlockers(of: $0.id).isEmpty }
    }

    /// Completes every open blocker of `id`, then `id`. A blocker that is itself blocked is left
    /// alone and `id` stays open (returns false): nothing is written then. REGISTERS UNDO: one step
    /// that reopens everything.
    @discardableResult
    public func completeWithBlockers(_ id: UUID) -> Bool {
        guard task(id) != nil, canCompleteWithBlockers(id) else { return false }
        let blockers = openBlockers(of: id).map(\.id)
        groupedUndo("Complete") {
            for b in blockers { complete(b) }
            complete(id)
        }
        return true
    }

    /// Drops every OPEN blocker from what `id` waits on (done ones and other ids stay), then
    /// completes `id`. REGISTERS UNDO: one step that reopens `id` and restores the dependencies.
    public func completeRemovingBlockers(_ id: UUID) {
        guard let t = task(id) else { return }
        let drop = Set(openBlockers(of: id).map(\.id))
        let keep = t.waitsOn.filter { !drop.contains($0) }
        groupedUndo("Complete") {
            if !drop.isEmpty { setWaitsOn(id, keep) }
            complete(id)
        }
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
        DependencyGraph.wouldCycle(id, waitingOn: other, edges: edgeMap(allTasksIncludingSubtasks()))
    }

    /// What the "Waits on" picker offers `id`: open live tasks INCLUDING child tasks (a child is
    /// a full task and can be waited on), never the task itself, never one already chosen, never
    /// one that would close a loop. `query` is matched folded against `waitsOnDisplayName`, so
    /// typing a parent's title also lists its children. Sorted by that name, at most `limit`.
    public func waitsOnCandidates(for id: UUID, query: String, limit: Int = 8) -> [KTask] {
        guard let me = task(id) else { return [] }
        let all = allTasksIncludingSubtasks()
        let edges = edgeMap(all)
        let have = Set(me.waitsOn)
        let needle = KTextFold.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let named = all.compactMap { t -> (KTask, String)? in
            guard t.id != id, KStatus.open.contains(t.status), !have.contains(t.id) else { return nil }
            let name = KTextFold.fold(t.waitsOnDisplayName)
            guard needle.isEmpty || name.contains(needle) else { return nil }
            guard !DependencyGraph.wouldCycle(id, waitingOn: t.id, edges: edges) else { return nil }
            return (t, name)
        }
        return named
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.id.uuidString < $1.0.id.uuidString }
            .prefix(limit).map(\.0)
    }

    private func edgeMap(_ tasks: [KTask]) -> [UUID: [UUID]] {
        var m: [UUID: [UUID]] = [:]
        for t in tasks where !t.waitsOnIDs.isEmpty { m[t.id] = t.waitsOn }
        return m
    }

    private func acceptedWaitsOn(_ id: UUID, _ ids: [UUID]) -> (accepted: [UUID], allOK: Bool) {
        let all = allTasksIncludingSubtasks()
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

extension KTask {
    /// How a dependency names this task: "Parent › Child" for a child task (its title alone
    /// is ambiguous outside its parent's row), else the title.
    public var waitsOnDisplayName: String {
        guard let parent else { return title }
        return parent.title + " › " + title
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
