import Foundation

/// Fully deterministic candidate selection for Impuls and DayPlan.
/// No async, no network: the card renders in
/// < 100 ms. `Candidate.reason` is a plain string the caller renders.
public struct Candidate: Equatable, Sendable {
    public let taskID: UUID
    public let reason: String
    public let isDeterministic: Bool

    public init(taskID: UUID, reason: String, isDeterministic: Bool = true) {
        self.taskID = taskID
        self.reason = reason
        self.isDeterministic = isDeterministic
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
    public func candidates(energy: KEnergyLevel,
                           count: Int = 5,
                           maxDeep: Bool,
                           today: Int,
                           tasks: [KTask]) -> [Candidate] {
        // Base pool: active status, not archived.
        var pool = tasks.filter { t in
            KStatus.active.contains(t.status) && !t.isProjectArchived
        }
        if !maxDeep {
            // Low/Mid energy: exclude deep tasks outright.
            pool = pool.filter { $0.depth != .deep }
        }

        // Branch rules (adhd-4):
        //  Low:  shallow AND <= 15 min, dread==false first.
        //  Mid:  priority-first, dread as tiebreak only.
        //  High: everything allowed, dread ignored.
        var ranked: [(t: KTask, score: Int, reason: String)]
        switch energy {
        case .low:
            let shallow = pool.filter {
                $0.depth == .shallow && ($0.estimateMinutes ?? 999) <= 15
            }
            let rest = pool.filter { !shallow.contains($0) }
            let shallowSorted = shallow.sorted {
                if $0.dread != $1.dread { return !$0.dread } // non-dread first
                return Ordering.manual($0, $1)
            }
            if shallowSorted.isEmpty {
                ranked = rest.map { ($0, 0, "Nothing shallow left") }
            } else {
                ranked = shallowSorted.map {
                    ($0, 0, $0.dread ? "Shallow, but you have been avoiding it" : "Shallow and quick")
                }
            }
        case .mid:
            ranked = pool.map { t in
                let s = t.priorityRaw * 10 + (t.dread ? 0 : 1)
                return (t, s, "Next by priority")
            }
        case .high:
            ranked = pool.map { t in
                let s = t.priorityRaw * 10 + (t.dueDay.map { 100 - ($0 - today) } ?? 0)
                return (t, s, "Good energy match")
            }
        }

        // Stable ordering: score desc, then dueDay asc nil-last, then the
        // manual order chain (§5.3) so equal scores never shuffle.
        let ordered = ranked.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            let ad = a.t.dueDay ?? Int.max
            let bd = b.t.dueDay ?? Int.max
            if ad != bd { return ad < bd }
            return Ordering.manual(a.t, b.t)
        }
        return ordered.prefix(count).map { Candidate(taskID: $0.t.id, reason: $0.reason) }
    }
}
