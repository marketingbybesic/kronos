// Kronos/Detail/InspectorDropHint.swift
// The one-time "Drop a file or email here" line under Links in the inspector: the inspector has
// always taken a dropped file, folder or Mail message, and nothing said so. It shows on the first
// task whose Links are empty, stays for as long as that view lives, and is not shown again once it
// has appeared. Foundation-only so a self-test compiles it as it is.
import Foundation
import KronosCore

enum InspectorDropHint {
    static let seenKey = "kronos.inspector.dropHintSeen"

    /// Whether the hint is still owed. A view reads this once when it is created and keeps the answer
    /// for its own lifetime, so the line does not vanish under the person's eyes.
    static func shouldShow(defaults: UserDefaults = KronosEnv.defaults) -> Bool {
        !defaults.bool(forKey: seenKey)
    }

    static func markSeen(defaults: UserDefaults = KronosEnv.defaults) {
        defaults.set(true, forKey: seenKey)
    }
}
