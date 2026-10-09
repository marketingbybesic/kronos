import Foundation

/// Fully deterministic candidate selection for Impuls and DayPlan.
/// No async, no network: the card renders in
/// < 100 ms. `Candidate.reason` is a plain string the caller renders.
public struct Candidate: Equatable, Sendable {
    public let taskID: UUID
    public let reason: String
    public let isDeterministic: Bool
    /// The task carries the dread flag. Never rendered; callers use it to record a dread pick
    /// in their `DreadServing`.
    public let isDread: Bool

    public init(taskID: UUID, reason: String, isDeterministic: Bool = true, isDread: Bool = false) {
        self.taskID = taskID
        self.reason = reason
        self.isDeterministic = isDeterministic
        self.isDread = isDread
    }
}

/// What the caller remembers about dread picks so the engine can serve at most one a day and
/// never two in a row. Pure value: the engine never stores it, the caller persists it.
public struct DreadServing: Equatable, Sendable {
    /// Day number of the last dread pick shown, nil when none yet.
    public var servedDay: Int?
    /// The most recent pick shown was a dread task.
    public var lastPickWasDread: Bool

    public init(servedDay: Int? = nil, lastPickWasDread: Bool = false) {
        self.servedDay = servedDay
        self.lastPickWasDread = lastPickWasDread
    }

    /// A dread task may be served now: none yet today and the previous pick was not one.
    public func canServe(today: Int) -> Bool { servedDay != today && !lastPickWasDread }

    /// The state after `pick` was shown on `today`.
    public func recording(_ pick: Candidate?, today: Int) -> DreadServing {
        guard let pick else { return self }
        return DreadServing(servedDay: pick.isDread ? today : servedDay, lastPickWasDread: pick.isDread)
    }
}

public struct RankingEngine: Sendable {

    public init() {}

    /// - Parameters:
    ///   - energy: current level.
    ///   - count: how many candidates to return.
    ///   - maxDeep: whether deep tasks are allowed (High energy only by
    ///     default callers).
    ///   - today: injectable day number.
    ///   - tasks: the caller's already-fetched pool. The engine does not
    ///     fetch, so it stays pure and testable.
    ///   - dreadServing: the caller's dread memory. nil leaves the order untouched; otherwise,
    ///     at Mid/High energy one dread task is served first when allowed (once a day, never
    ///     twice in a row), and when it is not allowed the first candidate is never a dread task.
    public func candidates(energy: KEnergyLevel,
                           count: Int = 5,
                           maxDeep: Bool,
                           today: Int,
                           tasks: [KTask]) -> [Candidate] {
        candidates(energy: energy, count: count, maxDeep: maxDeep, today: today, tasks: tasks, dreadServing: nil)
    }

    /// Same as above with the caller's dread memory (see `DreadServing`).
    public func candidates(energy: KEnergyLevel,
                           count: Int = 5,
                           maxDeep: Bool,
                           today: Int,
                           tasks: [KTask],
                           dreadServing: DreadServing?) -> [Candidate] {
        // Base pool: active status, not archived, not an agent proposal still waiting for review
        // (a pending proposal is invisible everywhere until the person decides on it).
        var pool = tasks.filter { t in
            KStatus.active.contains(t.status) && !t.isProjectArchived && !Self.isPendingProposal(t)
        }
        // Perf: `DependencyGraph.blocked` builds an id->open Set over the whole `tasks` pool
        // (thousands of rows at scale) even when nothing in `pool` has a dependency at all —
        // the common case. Skip the call entirely then; its own inner loop only ever examines
        // tasks with a non-empty `waitsOnIDs`, so the result would be empty regardless.
        // w22e: a task waiting on an open task is not a next action. `tasks` is the caller's
        // full live pool, so it also answers "is the blocker still open".
        let blocked: Set<UUID> = pool.contains(where: { !$0.waitsOnIDs.isEmpty })
            ? DependencyGraph.blocked(in: pool, lookup: tasks)
            : []
        if !blocked.isEmpty { pool = pool.filter { !blocked.contains($0.id) } }
        if !maxDeep {
            // Low/Mid energy: exclude deep tasks outright.
            pool = pool.filter { $0.depth != .deep }
        }

        // Branch rules (adhd-4):
        //  Low:  shallow AND <= 15 min, in manual order.
        //  Mid:  priority-first.
        //  High: everything allowed, priority and due date.
        // Dread never changes a score or a reason: the only dread rule is the once-a-day
        // serving applied after the sort.
        // Perf: `due` is computed here, once per pool task, instead of inside the sort
        // comparator below — `effectiveDue` walks `orderedChildren` (a SwiftData relationship
        // fault + filter + sort), so calling it twice per comparison made an O(n log n)-times
        // cost out of what only needs to be O(n).
        var ranked: [(t: KTask, score: Int, due: Int, reason: String)]
        switch energy {
        case .low:
            let shallow = pool.filter {
                $0.depth == .shallow && ($0.estimateMinutes ?? 999) <= 15
            }
            let rest = pool.filter { !shallow.contains($0) }
            let shallowSorted = shallow.sorted(by: Ordering.manual)
            if shallowSorted.isEmpty {
                ranked = rest.map { ($0, 0, $0.effectiveDue ?? Int.max, "Nothing shallow left") }
            } else {
                ranked = shallowSorted.map { ($0, 0, $0.effectiveDue ?? Int.max, "Shallow and quick") }
            }
        case .mid:
            ranked = pool.map { t in
                return (t, t.priorityRaw * 10, t.effectiveDue ?? Int.max, "Next by priority")
            }
        case .high:
            ranked = pool.map { t in
                let due = t.effectiveDue
                let s = t.priorityRaw * 10 + (due.map { 100 - ($0 - today) } ?? 0)
                return (t, s, due ?? Int.max, "Good energy match")
            }
        }

        // Stable ordering: score desc, then dueDay asc nil-last, then the
        // manual order chain (§5.3) so equal scores never shuffle.
        let ordered = ranked.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.due != b.due { return a.due < b.due }
            return Ordering.manual(a.t, b.t)
        }
        var result = ordered.map { Candidate(taskID: $0.t.id, reason: $0.reason, isDread: $0.t.dread) }
        if let serving = dreadServing {
            result = Self.applyDreadServing(result, energy: energy, today: today, serving: serving)
        }
        return Array(result.prefix(count))
    }

    /// Once a day at Mid/High the best-ranked dread task goes first; when serving is not allowed
    /// (already served today, or the last pick was one) a dread task never leads. Everything
    /// else keeps its order.
    /// An agent proposal the person has not decided on yet (the same value Up next skips).
    static func isPendingProposal(_ task: KTask) -> Bool {
        task.reviewRaw == NextEligibility.reviewPending
    }

    private static func applyDreadServing(_ list: [Candidate], energy: KEnergyLevel, today: Int,
                                          serving: DreadServing) -> [Candidate] {
        var out = list
        if serving.canServe(today: today) {
            guard energy != .low, let i = out.firstIndex(where: { $0.isDread }), i > 0 else { return out }
            out.insert(out.remove(at: i), at: 0)
        } else if out.first?.isDread == true, let i = out.firstIndex(where: { !$0.isDread }) {
            out.insert(out.remove(at: i), at: 0)
        }
        return out
    }
}
