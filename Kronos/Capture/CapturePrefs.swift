// Kronos/Capture/CapturePrefs.swift
// A visible "Use AI" switch on the paste view, persisted. Hermetic under KRONOS_SNAPSHOT,
// same shape as Kronos/Triage/TriagePrefs.swift.
import Foundation

enum CapturePrefs {
    private static let useAIKey = "kronos.capture.useAI"

    private static var defaults: UserDefaults {
        ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT"] != nil ? .captureSnapshotScratch : .standard
    }

    /// Default ON: matches today's shipped behaviour (the AI upgrade already ran whenever
    /// `model.ai` existed) — the switch is for turning it OFF, not opting in.
    static var useAI: Bool {
        get { defaults.object(forKey: useAIKey) == nil ? true : defaults.bool(forKey: useAIKey) }
        set { defaults.set(newValue, forKey: useAIKey) }
    }
}

private extension UserDefaults {
    /// One throwaway suite per snapshot process — never the real `kronos.capture.*` key during
    /// a gate run, matching AppearancePrefs'/TriagePrefs' own `.snapshotScratch`.
    static let captureSnapshotScratch = UserDefaults(suiteName: "kronos.snapshot.capture." + UUID().uuidString) ?? .standard
}
