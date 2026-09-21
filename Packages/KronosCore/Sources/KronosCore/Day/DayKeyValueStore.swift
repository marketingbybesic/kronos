// A minimal injectable key-value seam for the day-change idempotency guard
// (data-model.md §8.3). `AppSettings` — the real per-device settings object —
// belongs to another leaf (Settings, app target); this protocol lets
// DayChangeCoordinator and NightSweep persist one integer each without
// depending on it, and lets tests use an in-memory fake instead of the real
// UserDefaults suite.

import Foundation

/// Reads and writes a handful of integers by string key. `UserDefaults`
/// already conforms; production code passes `.standard`.
public protocol DayKeyValueStore: AnyObject, Sendable {
    func integer(forKey key: String) -> Int
    func setInteger(_ value: Int, forKey key: String)
}

extension UserDefaults: DayKeyValueStore {
    public func setInteger(_ value: Int, forKey key: String) { set(value, forKey: key) }
}

/// In-memory fake for tests — no UserDefaults suite to clean up between runs.
public final class FixtureKeyValueStore: DayKeyValueStore, @unchecked Sendable {
    private var values: [String: Int] = [:]
    public init() {}
    public func integer(forKey key: String) -> Int { values[key] ?? 0 }
    public func setInteger(_ value: Int, forKey key: String) { values[key] = value }
}
