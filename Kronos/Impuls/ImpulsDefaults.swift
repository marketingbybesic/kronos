// Kronos/Impuls/ImpulsDefaults.swift
// The small decisions Impuls, the morning plan and the Now card used to push onto the person,
// made once and in one place. Foundation only, so scripts/impuls-defaults-selftest.swift compiles
// this REAL file (no KronosCore, no SwiftUI); the screens map the results onto their own types.

import Foundation

/// A handful of integers by string key. `UserDefaults` is made to conform in ImpulsMemory.swift;
/// the self-test uses an in-memory class.
protocol ImpulsIntStore: AnyObject {
    func integer(forKey key: String) -> Int
    func setInteger(_ value: Int, forKey key: String)
}

enum ImpulsDefaults {
    enum Energy: Int { case low = 0, mid = 1, high = 2 }

    /// The last choice made today wins. With none, evening and night start low (a tired brain
    /// should meet the smallest task first) and the rest of the day starts mid. Never high:
    /// a wrongly-high default shows a deep task to someone who has not asked for one.
    static func energy(remembered: Energy?, hour: Int) -> Energy {
        if let remembered { return remembered }
        return (hour >= 19 || hour < 5) ? .low : .mid
    }

    // MARK: Another

    /// "Another" may be asked this many times per card session.
    static let anotherCap = 3

    /// The button exists only while it can do something: under the cap and with a next card.
    /// Never greyed out, so the row never jumps.
    static func showsAnother(used: Int, hasNext: Bool) -> Bool {
        used < anotherCap && hasNext
    }

    // MARK: Hero line

    struct Hero: Equatable {
        /// The big line.
        let hero: String
        /// The smaller line under it; nil when it would only repeat the hero.
        let secondary: String?
        /// A generic first move says nothing a person can act on, so Start sends them to the notes.
        let startOpensNotes: Bool
    }

    /// A generic template ("Open the notes for this task and write the first line") is a decision in
    /// disguise: the title is the honest hero then, with no second line repeating it, and Start puts
    /// the cursor in the notes.
    static func hero(move: String, moveIsGeneric: Bool, title: String) -> Hero {
        let trimmed = move.trimmingCharacters(in: .whitespacesAndNewlines)
        if moveIsGeneric || trimmed.isEmpty {
            return Hero(hero: title, secondary: nil, startOpensNotes: true)
        }
        return Hero(hero: trimmed, secondary: title, startOpensNotes: false)
    }

    // MARK: Large tasks

    /// Effort L and XL (raw 4 and 5) are Large.
    static func isLarge(effortRaw: Int) -> Bool { effortRaw >= 4 }

    /// A silent breakdown runs for a Large task with no steps that has not been broken down before.
    static func shouldAutoBreakdown(effortRaw: Int, childCount: Int, brokenBefore: Bool) -> Bool {
        isLarge(effortRaw: effortRaw) && childCount == 0 && !brokenBefore
    }

    // MARK: Morning plan

    struct PlanRow: Equatable {
        let id: UUID
        /// The task's effective deadline (its own or its earliest open step's).
        let dueDay: Int?
        let plannedDay: Int?
    }

    /// The tasks that need a planned day written: not already due today or earlier, and not already
    /// planned for today or earlier (those are in Today without any write). The deadline is never touched.
    static func idsNeedingPlan(_ rows: [PlanRow], today: Int) -> [UUID] {
        rows.filter { row in
            let dueNow = row.dueDay.map { $0 <= today } ?? false
            let plannedNow = row.plannedDay.map { $0 <= today } ?? false
            return !dueNow && !plannedNow
        }.map(\.id)
    }

    // MARK: Sunday sweep entry

    /// The morning card offers Sweep on Sundays only (Calendar weekday 1).
    static func offersSweep(weekday: Int) -> Bool { weekday == 1 }

    // MARK: Dread serving (per device)

    private static let dreadDayKey = "kronos.impuls.dread.servedDay"
    private static let dreadLastKey = "kronos.impuls.dread.lastWasDread"

    /// 0 in the store means "never": day numbers are positive.
    static func loadDread(_ store: ImpulsIntStore) -> (servedDay: Int?, lastWasDread: Bool) {
        let day = store.integer(forKey: dreadDayKey)
        return (day > 0 ? day : nil, store.integer(forKey: dreadLastKey) == 1)
    }

    static func saveDread(servedDay: Int?, lastWasDread: Bool, to store: ImpulsIntStore) {
        store.setInteger(servedDay ?? 0, forKey: dreadDayKey)
        store.setInteger(lastWasDread ? 1 : 0, forKey: dreadLastKey)
    }
}

/// "Not now": the task is left out of Impuls and the morning plan for the rest of the day. One
/// integer per task (the day it was set aside), so nothing is added to the store schema.
enum ImpulsNotNow {
    static let keyPrefix = "kronos.impuls.notnow."

    static func key(_ id: UUID) -> String { keyPrefix + id.uuidString }

    static func mark(_ id: UUID, today: Int, in store: ImpulsIntStore) {
        guard store.integer(forKey: key(id)) != today else { return }
        store.setInteger(today, forKey: key(id))
    }

    static func isExcluded(_ id: UUID, today: Int, in store: ImpulsIntStore) -> Bool {
        store.integer(forKey: key(id)) == today
    }

    static func excluded(among ids: [UUID], today: Int, in store: ImpulsIntStore) -> Set<UUID> {
        Set(ids.filter { isExcluded($0, today: today, in: store) })
    }
}
