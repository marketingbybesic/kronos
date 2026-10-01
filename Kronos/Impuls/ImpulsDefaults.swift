// Kronos/Impuls/ImpulsDefaults.swift
// Two tiny decisions Impuls used to push onto the user: which energy to start from, and where
// Start should land. Foundation only, so scripts/impuls-defaults-selftest.swift compiles this
// REAL file (no KronosCore); ImpulsScreen maps the results onto KEnergyLevel / ListScope.

import Foundation

enum ImpulsDefaults {
    enum Energy: Int { case low = 0, mid = 1, high = 2 }
    enum StartScope: Equatable { case project(UUID), all }

    /// The last choice made today wins. With none, evening and night start low (a tired brain
    /// should meet the smallest task first) and the rest of the day starts mid. Never high:
    /// a wrongly-high default shows a deep task to someone who has not asked for one.
    static func energy(remembered: Energy?, hour: Int) -> Energy {
        if let remembered { return remembered }
        return (hour >= 19 || hour < 5) ? .low : .mid
    }

    /// Start opens the list the task actually lives in: its project, else "All" (open tasks,
    /// so the just-started one is always a member). Inbox is wrong for any project task, and
    /// for a project-less one it drops a task that may be dated or in progress into a queue
    /// meant for untriaged work.
    static func startScope(projectID: UUID?) -> StartScope {
        projectID.map(StartScope.project) ?? .all
    }
}
