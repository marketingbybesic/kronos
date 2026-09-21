// Kronos/Triage/TriagePrefs.swift
//
// A visible switch to turn the AI-upgraded triage suggestion on or off, persisted. Hermetic
// under KRONOS_SNAPSHOT, same shape as Kronos/DesignSystem/AppearancePrefs.swift.
import Foundation

enum TriagePrefs {
    private static let aiEnabledKey = "kronos.triage.aiSuggestionsEnabled"

    private static var defaults: UserDefaults {
        ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT"] != nil ? .triageSnapshotScratch : .standard
    }

    /// Default ON: matches today's shipped behaviour (the AI upgrade already ran whenever
    /// `model.ai` existed) — the switch is for turning it OFF, not opting in.
    static var aiSuggestionsEnabled: Bool {
        get { defaults.object(forKey: aiEnabledKey) == nil ? true : defaults.bool(forKey: aiEnabledKey) }
        set { defaults.set(newValue, forKey: aiEnabledKey) }
    }
}

private extension UserDefaults {
    /// One throwaway suite per snapshot process — never the real `kronos.triage.*` key during
    /// a gate run, matching AppearancePrefs' own `.snapshotScratch`.
    static let triageSnapshotScratch = UserDefaults(suiteName: "kronos.snapshot.triage." + UUID().uuidString) ?? .standard
}
