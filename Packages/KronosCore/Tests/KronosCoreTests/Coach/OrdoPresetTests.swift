import Testing
import Foundation
@testable import KronosCore

struct OrdoPresetTests {

    @Test func presetRoundTripsThroughCodable() {
        let preset = OrdoPreset(id: "custom-1", name: "My mix",
                                sort: [.desc(.priority), .asc(.deadline)],
                                filter: .empty, usesCoachRanking: true, energy: .high)
        let data = try! JSONEncoder().encode(preset)
        let decoded = try! JSONDecoder().decode(OrdoPreset.self, from: data)
        #expect(decoded == preset)
    }

    @Test func builtInPresetsHaveStableIDs() {
        #expect(OrdoPreset.deadline.id == "deadline")
        #expect(OrdoPreset.quickwins.id == "quickwins")
        #expect(OrdoPreset.deepwork.id == "deepwork")
        #expect(OrdoPreset.priority.id == "priority")
        #expect(OrdoPreset.coach.id == "coach")
        // Every built-in is reachable through the resolver's fallback path,
        // so an id typo here would also break `OrdoPresetResolver`.
        let ids = Set(OrdoPreset.builtIns.map(\.id))
        #expect(ids == ["deadline", "quickwins", "deepwork", "priority", "coach"])
    }

    @Test func resolverUsesDefaultForScopeWhenSet() {
        var settings = CoachSettings()
        settings.defaultPresetByScope["project.abc"] = OrdoPreset.deepworkID
        let resolved = OrdoPresetResolver.preset(for: "project.abc", settings: settings)
        #expect(resolved.id == OrdoPreset.deepworkID)
    }

    @Test func resolverFallsBackToPriorityWithNoDefault() {
        let settings = CoachSettings()
        let resolved = OrdoPresetResolver.preset(for: "inbox", settings: settings)
        #expect(resolved.id == OrdoPreset.priorityID)
    }
}
