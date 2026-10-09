// Kronos/Settings/SettingsAgentActivityViewFixtures.swift
// Split out of SettingsAgentActivityView.swift (verify-hardcoded.mjs exempts *Fixtures.swift by
// name — sample prose here is snapshot/preview scaffolding, allowed to be English-only, per the
// same rule SettingsAgentsTab's own fixture rows rely on).

import KronosCore

extension AgentActivityController {
    static func fixtureData() -> ([Row], [Count]) {
        let rows = [
            Row(id: 4, verbLabel: verbLabel(ActivityVerb.completed), title: "Confirm venue for the Q4 offsite",
               relativeTime: "2 hours ago", byline: nil),
            Row(id: 3, verbLabel: verbLabel(ActivityVerb.approved), title: "Confirm venue for the Q4 offsite",
               relativeTime: "3 hours ago", byline: String(localized: "agents.activity.actor.owner")),
            Row(id: 2, verbLabel: verbLabel(ActivityVerb.commented), title: "Draft the release notes",
               relativeTime: "Yesterday", byline: String(localized: "agents.activity.actor.owner")),
            Row(id: 1, verbLabel: verbLabel(ActivityVerb.created), title: "Draft the release notes",
               relativeTime: "2 days ago", byline: nil),
        ]
        let counts = [
            Count(verb: ActivityVerb.created, label: verbLabel(ActivityVerb.created), count: 1),
            Count(verb: ActivityVerb.completed, label: verbLabel(ActivityVerb.completed), count: 1),
            Count(verb: ActivityVerb.approved, label: verbLabel(ActivityVerb.approved), count: 1),
            Count(verb: ActivityVerb.commented, label: verbLabel(ActivityVerb.commented), count: 1),
        ]
        return (rows, counts)
    }
}
