// Part of the frozen contract surface. See Contracts.swift.
//
// The deterministic ranking surface. `Candidate` itself is declared beside
// the concrete implementation in Ranking/RankingEngine.swift, because that
// type shipped before this protocol existed and consumers already import it.
//
// Named `RankingProviding` rather than `RankingEngine` because a concrete
// `RankingEngine` struct already exists and is already tested. The protocol
// is adapted to the code, not the code to the protocol.

import Foundation

/// Deterministic candidate selection for Impuls and the morning plan.
///
/// Synchronous by contract: no `async`, no I/O, no network, no AI. The Impuls
/// card renders inside 100 ms (SPEC §12.1, adhd-2), which is only possible if
/// nothing here can await. An implementation that needed to await would be
/// the wrong implementation.
///
/// The engine does not fetch. Callers pass the pool they already hold, which
/// keeps implementations pure and makes every ranking test a value test.
///
/// Not actor-isolated: ranking is a pure function over rows the caller
/// already owns, so it runs wherever the caller is. `KTask` is a SwiftData
/// model and therefore not `Sendable`, which is exactly why the pool is a
/// parameter and never crosses an isolation boundary on its own.
public protocol RankingProviding {
    /// Rank the pool and return at most `count` candidates, best first.
    ///
    /// - Parameters:
    ///   - energy: the user's stated energy level. Low admits only shallow,
    ///     short work; High admits everything and ignores `dread`.
    ///   - count: maximum candidates to return.
    ///   - maxDeep: whether deep tasks may appear at all. Callers pass `true`
    ///     only for High energy.
    ///   - today: injected day number (days since epoch, local calendar), so
    ///     due-date rules are testable without touching the clock.
    ///   - tasks: the already-fetched pool, which the caller is expected to
    ///     have fetched live — `TaskStore.allTasks()` already excludes
    ///     soft-deleted rows. The implementation additionally drops rows whose
    ///     status is not active and rows in an archived project, so passing a
    ///     wider pool is safe but passing deleted rows is the caller's bug.
    /// - Returns: at most `count` candidates. May be empty; an empty result
    ///   is a real state (nothing eligible), not an error.
    func candidates(energy: KEnergyLevel,
                    count: Int,
                    maxDeep: Bool,
                    today: Int,
                    tasks: [KTask]) -> [Candidate]
}

extension RankingEngine: RankingProviding {}
