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

    /// True when a task is missing any of the four fields triage covers: priority, effort,
    /// deadline, project. Only these four — depth/estimate/labels are not part of triage here
    /// (that is AutoTriage's broader fill).
    static func isMissingData(_ task: KTask) -> Bool {
        task.priority == .none || task.effort == .none || task.dueDay == nil || task.project == nil
    }

    /// Oldest-first (by `createdAt`, id as a stable tie-break), open statuses only, tasks
    /// missing at least one of the four fields. Stable order: the same input always yields
    /// the same sequence, so the flow does not reshuffle mid-session.
    static func ordered(in tasks: [KTask]) -> [KTask] {
        tasks
            .filter { KStatus.open.contains($0.status) && isMissingData($0) }
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
