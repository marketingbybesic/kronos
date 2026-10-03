// Kronos/Triage/TriageQueue.swift
//
// A simple way to triage tasks: an option to go in order through every task that is missing
// data, with an automated suggestion for each one.
//
// Pure, synchronous, Core types only (no SwiftUI, no store) so `scripts/triage-selftest.swift`
// can compile this file alone against a hand-written table — same shape as
// `TriageContextBuilder`/`NeighbourTriage`.
import Foundation
import KronosCore

enum TriageQueue {

    /// True when a task is missing a field AutoTriage fills: priority, effort, project. A missing
    /// deadline is normal (AutoTriage only sets one from words in the title), so it never counts:
    /// the badge must be able to reach zero.
    static func isMissingData(_ task: KTask) -> Bool {
        task.priority == .none || task.effort == .none || task.project == nil
    }

    /// Oldest-first (by `createdAt`, id as a stable tie-break), open statuses only, tasks
    /// missing priority, effort or project that nobody has triaged yet. Stable order: the same
    /// input always yields the same sequence, so the flow does not reshuffle mid-session.
    ///
    /// `needsTriage` is cleared once a task has been through triage (Return here, or AutoTriage
    /// in the background). Without it, a task whose effort stays empty on purpose came back
    /// forever and the badge sat at 22 next to "All 22" (audit F2).
    static func ordered(in tasks: [KTask]) -> [KTask] {
        tasks
            .filter { !$0.isSubtask && $0.reviewRaw != 1 && KStatus.open.contains($0.status) && $0.needsTriage && isMissingData($0) }
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    /// `TriageFlowView`'s entry-point count (sidebar/header badge, palette command).
    static func count(in tasks: [KTask]) -> Int {
        ordered(in: tasks).count
    }
}
