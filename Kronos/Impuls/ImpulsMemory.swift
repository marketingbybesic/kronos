// Kronos/Impuls/ImpulsMemory.swift
// What Impuls remembers between opens, all in `KronosEnv.defaults` (the real preferences normally, a
// throwaway suite in a snapshot or live test), nothing in the store schema:
//   - today's energy: ONE value for the whole app (Impuls, the morning plan, the menu bar)
//   - the dread-serving state of this device
//   - tasks set aside with "Not now" for today
//   - tasks that already got their silent breakdown
import Foundation
import KronosCore

extension UserDefaults: ImpulsIntStore {}

/// Persists the last chosen energy for today, keyed by day so yesterday's answer never answers
/// today's question.
enum ImpulsEnergyMemory {
    private static let dayKey = "kronos.impuls.energy.day"
    private static let levelKey = "kronos.impuls.energy.level"
    private static var defaults: UserDefaults { KronosEnv.defaults }

    static func rememberToday(_ energy: KEnergyLevel) {
        let d = defaults
        let today = Day.today(calendar: KronosLocale.calendar)
        guard d.integer(forKey: dayKey) != today || d.object(forKey: levelKey) == nil || d.integer(forKey: levelKey) != energy.rawValue else { return }
        d.set(today, forKey: dayKey)
        d.set(energy.rawValue, forKey: levelKey)
    }

    /// nil when nothing was remembered yet, or the stored day is not today.
    static func todayEnergy() -> KEnergyLevel? {
        let d = defaults
        guard d.object(forKey: dayKey) != nil, d.integer(forKey: dayKey) == Day.today(calendar: KronosLocale.calendar),
              d.object(forKey: levelKey) != nil else { return nil }
        return KEnergyLevel(rawValue: d.integer(forKey: levelKey))
    }

    /// The energy every surface uses right now: today's answer, else a time-of-day default.
    /// Hour 12 under the snapshot harness so shots do not depend on the clock.
    static func current(now: Date = Date()) -> KEnergyLevel {
        let hour = KronosEnv.isSnapshot ? 12 : KronosLocale.calendar.component(.hour, from: now)
        let remembered = todayEnergy().flatMap { ImpulsDefaults.Energy(rawValue: $0.rawValue) }
        return KEnergyLevel(rawValue: ImpulsDefaults.energy(remembered: remembered, hour: hour).rawValue) ?? .mid
    }
}

/// The dread-serving state of this device (at most one dread task a day, never two picks in a row).
enum ImpulsDreadMemory {
    static func load() -> DreadServing {
        let s = ImpulsDefaults.loadDread(KronosEnv.defaults)
        return DreadServing(servedDay: s.servedDay, lastPickWasDread: s.lastWasDread)
    }

    static func save(_ serving: DreadServing) {
        ImpulsDefaults.saveDread(servedDay: serving.servedDay, lastWasDread: serving.lastPickWasDread, to: KronosEnv.defaults)
    }

    /// Records a pick that was just shown and persists the new state.
    @discardableResult
    static func record(_ pick: Candidate?, today: Int) -> DreadServing {
        let next = load().recording(pick, today: today)
        save(next)
        return next
    }
}

/// "Not now" for today, and the one-time marker of the silent breakdown.
enum ImpulsDayMemory {
    private static let stepsPrefix = "kronos.impuls.autosteps."
    private static var defaults: UserDefaults { KronosEnv.defaults }

    static func setAside(_ id: UUID, today: Int) { ImpulsNotNow.mark(id, today: today, in: defaults) }

    static func setAsideToday(among ids: [UUID], today: Int) -> Set<UUID> {
        ImpulsNotNow.excluded(among: ids, today: today, in: defaults)
    }

    static func hadBreakdown(_ id: UUID) -> Bool { defaults.integer(forKey: stepsPrefix + id.uuidString) == 1 }
    static func markBreakdown(_ id: UUID) { defaults.set(1, forKey: stepsPrefix + id.uuidString) }

    /// Drops yesterday's "Not now" keys and breakdown markers of tasks that no longer exist, so the
    /// preferences domain does not grow by one key per task forever.
    static func prune(today: Int, liveTaskIDs: Set<UUID>) {
        let d = defaults
        for (key, value) in d.dictionaryRepresentation() {
            if key.hasPrefix(ImpulsNotNow.keyPrefix), let day = value as? Int, day < today {
                d.removeObject(forKey: key)
            } else if key.hasPrefix(stepsPrefix),
                      let id = UUID(uuidString: String(key.dropFirst(stepsPrefix.count))), !liveTaskIDs.contains(id) {
                d.removeObject(forKey: key)
            }
        }
    }
}
