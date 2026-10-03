// Kronos/Triage/ReviewSnooze.swift
//
// "Not now" on a proposal: it leaves the Review queue and comes back the next day. The task
// itself stays pending and hidden, so nothing about it changes in the store; the comeback day
// is a small per-device table in the app's defaults (KronosEnv.defaults, hermetic in tests).
import Foundation
import KronosCore

enum ReviewSnooze {
    private static let key = "kronos.review.snoozedUntil"

    /// task id -> day number it comes back on.
    static var table: [UUID: Int] {
        let raw = KronosEnv.defaults.dictionary(forKey: key) as? [String: Int] ?? [:]
        return Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in UUID(uuidString: k).map { ($0, v) } })
    }

    static func snooze(_ ids: [UUID], until day: Int) {
        var raw = KronosEnv.defaults.dictionary(forKey: key) as? [String: Int] ?? [:]
        for id in ids { raw[id.uuidString] = day }
        KronosEnv.defaults.set(raw, forKey: key)
    }

    /// Takes the given proposals back out of "not now" (the pill's Undo).
    static func remove(_ ids: [UUID]) {
        var raw = KronosEnv.defaults.dictionary(forKey: key) as? [String: Int] ?? [:]
        for id in ids { raw.removeValue(forKey: id.uuidString) }
        KronosEnv.defaults.set(raw, forKey: key)
    }

    /// Forgets every "not now" (the live test starts each step from a clean table).
    static func clear() { KronosEnv.defaults.removeObject(forKey: key) }

    /// Drops entries whose day has come, so the table never grows.
    static func prune(today: Int) {
        let raw = KronosEnv.defaults.dictionary(forKey: key) as? [String: Int] ?? [:]
        let kept = raw.filter { $0.value > today }
        if kept.count != raw.count { KronosEnv.defaults.set(kept, forKey: key) }
    }
}
