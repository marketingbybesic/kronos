// Kronos/TimeBlocks/TimeBlocksPrefs.swift
// Whether the Time Blocks view is enabled at all (Settings > Coach toggle). Off by default:
// it is a new surface, not a replacement for the existing lists, until it is turned on.
// Hermetic under KRONOS_SNAPSHOT, matching every other controller in this app
// (AppearancePrefs, CoachModel).
import Foundation
import KronosCore

enum TimeBlocksPrefs {
    private static let enabledKey = "kronos.timeblocks.enabled"
    /// "Menu bar follows the current time block" — Settings > Coach, next to the
    /// Time blocks switch itself. Default ON; `Bool` reads false for an unset
    /// key, so this needs the same `object(forKey:) == nil` default-true pattern
    /// `MenuBarPrefs.fillToCamera` already uses.
    private static let followsBlockKey = "kronos.timeblocks.menubarFollows"

    private static var defaults: UserDefaults {
        ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT"] != nil ? .timeBlocksSnapshotScratch : .standard
    }

    static var isEnabled: Bool {
        get { defaults.bool(forKey: enabledKey) }
        set { defaults.set(newValue, forKey: enabledKey) }
    }

    static var menuBarFollows: Bool {
        get { defaults.object(forKey: followsBlockKey) == nil ? true : defaults.bool(forKey: followsBlockKey) }
        set { defaults.set(newValue, forKey: followsBlockKey) }
    }

    /// The block last picked by hand in Time Blocks (arrows, day strip, or "Stay" on the
    /// ended-block prompt) — the one piece of screen-local state the menu bar also needs, so
    /// manual navigation updates the menu bar at once. `TimeBlocksModel` builds a fresh
    /// instance per render, so this is the only place the pick can live.
    ///
    /// ROOT CAUSE of a real bug: an earlier version cleared this the moment the picked block
    /// ended, which silently dropped the exact reported case (picked/arrived-at block ends,
    /// banner offers Stay/Switch, bar reverts to per-project focus). The rule is now: a
    /// manual pick holds across block-end and is cleared only by an explicit Switch/another
    /// pick (`setManualPick` called again) or a day change (`Day.today` no longer matches
    /// `manualEventDay`) — never by the block itself ending. The day is stored alongside the
    /// id, mirroring `ImpulsEnergyMemory`'s day-keyed memory, so a pick from yesterday can
    /// never silently answer today's question after an overnight sleep/relaunch.
    private static let manualEventIDKey = "kronos.timeblocks.manualEventID"
    private static let manualEventDayKey = "kronos.timeblocks.manualEventDay"

    /// The manually picked event id, or nil if there is none or it was made on a different day
    /// than today (a stale cross-midnight pick reads as absent rather than being trusted).
    static var manualEventID: String? {
        guard defaults.object(forKey: manualEventDayKey) != nil,
              defaults.integer(forKey: manualEventDayKey) == Day.today(calendar: KronosLocale.calendar) else { return nil }
        return defaults.string(forKey: manualEventIDKey)
    }

    /// Records `eventID` as today's manual pick. Call on every arrow/strip navigation and on
    /// "Stay" (so a block reached automatically and then chosen to stay on also becomes a
    /// real manual pick — auto-advance should only happen through the Switch answer or when
    /// there is no manual pick).
    static func setManualPick(eventID: String) {
        defaults.set(eventID, forKey: manualEventIDKey)
        defaults.set(Day.today(calendar: KronosLocale.calendar), forKey: manualEventDayKey)
    }

    static func clearManualPick() {
        defaults.removeObject(forKey: manualEventIDKey)
        defaults.removeObject(forKey: manualEventDayKey)
    }
}

private extension UserDefaults {
    /// One throwaway suite per snapshot process — a gate run never reads or writes the real
    /// `kronos.timeblocks.enabled` key.
    static let timeBlocksSnapshotScratch = UserDefaults(suiteName: "kronos.snapshot.timeblocks." + UUID().uuidString) ?? .standard
}
