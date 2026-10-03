// Kronos/MenuBar/MenuBarQuietLines.swift
// The quiet boundary lines of the menu bar: no timer, no counting, a line exists only at a
// threshold and is silent before it.
//   - "· 20 min left" inside an active calendar block, from 20 min before its end;
//   - "Next: X at 14:00" from 15 min before the next calendar event starts;
//   - one "been at this a while" after 90 min on the same pinned task.
// Foundation only, no KronosCore and no AppModel: every function takes `now`, so the caller
// feeds it `KronosClock.now` and `scripts/menubar-hit-selftest.swift` drives it with a hand
// advanced fake clock against hand-written threshold tables (compiled together with this
// exact file, never a mirror).
import Foundation

/// A calendar event reduced to what the lines need.
struct QuietEvent: Equatable {
    let title: String
    let start: Date
    let end: Date
}

enum MenuBarQuietLines {
    /// Seconds before a block's end from which "N min left" shows.
    static let timeLeftWindow: TimeInterval = 20 * 60
    /// Seconds before the next event from which "Next: X at T" shows.
    static let nextWindow: TimeInterval = 15 * 60
    /// Seconds on one pinned task before the single "been at this a while" line.
    static let longOnTaskAfter: TimeInterval = 90 * 60

    enum Line: Equatable {
        case timeLeft(minutes: Int)
        case next(title: String, start: Date)
        case longOnTask
    }

    /// The active event (`start <= now < end`) that ends first, when it ends within the window.
    /// Minutes round UP, so the last half minute reads "1 min left", never "0 min left".
    static func timeLeft(events: [QuietEvent], now: Date) -> Line? {
        let active = events.filter { $0.start <= now && now < $0.end }
        guard let soonest = active.min(by: { $0.end < $1.end }) else { return nil }
        let remaining = soonest.end.timeIntervalSince(now)
        guard remaining <= timeLeftWindow else { return nil }
        return .timeLeft(minutes: max(1, Int((remaining / 60).rounded(.up))))
    }

    /// The earliest event that has not started yet and starts within the window.
    static func next(events: [QuietEvent], now: Date) -> Line? {
        let upcoming = events.filter { $0.start > now && $0.start.timeIntervalSince(now) <= nextWindow }
        guard let soonest = upcoming.min(by: { $0.start < $1.start }) else { return nil }
        return .next(title: soonest.title, start: soonest.start)
    }

    /// `since` is when the current pinned task became the pin (nil: nothing pinned);
    /// `alreadyShown` is true once the line was shown for this stint.
    static func longOnTask(since: Date?, now: Date, alreadyShown: Bool) -> Line? {
        guard let since, !alreadyShown, now.timeIntervalSince(since) >= longOnTaskAfter else { return nil }
        return .longOnTask
    }

    /// The one line the popover shows. Priority: the event about to start, then the time left
    /// in the active block, then the long-on-task line.
    static func popoverLine(events: [QuietEvent], now: Date, since: Date?, alreadyShown: Bool) -> Line? {
        next(events: events, now: now)
            ?? timeLeft(events: events, now: now)
            ?? longOnTask(since: since, now: now, alreadyShown: alreadyShown)
    }

    /// The bar suffix: only the time left, nothing else ever rides on the bar.
    static func barSuffix(events: [QuietEvent], now: Date) -> Line? {
        timeLeft(events: events, now: now)
    }
}

/// Which task has been the pin and since when, plus whether its single "been at this a while"
/// line was already shown. Saved on every change, so quitting and reopening Kronos continues the
/// same stint instead of starting the 90 minutes again; a stint from an earlier day is dropped.
struct OnTaskTracker: Equatable {
    private(set) var taskID: UUID?
    private(set) var since: Date?
    private(set) var shownForStint = false

    init() {}

    private init(taskID: UUID, since: Date, shownForStint: Bool) {
        self.taskID = taskID
        self.since = since
        self.shownForStint = shownForStint
    }

    static let defaultsKey = "kronos.menubar.onTaskStint"

    /// The stint saved by an earlier run, when it began on the day of `now` (and not after it);
    /// otherwise a fresh tracker.
    static func restore(from defaults: UserDefaults, now: Date, calendar: Calendar) -> OnTaskTracker {
        guard let saved = defaults.dictionary(forKey: defaultsKey),
              let raw = saved["task"] as? String, let id = UUID(uuidString: raw),
              let start = (saved["since"] as? Double).map(Date.init(timeIntervalSince1970:)),
              start <= now, calendar.isDate(start, inSameDayAs: now) else { return OnTaskTracker() }
        return OnTaskTracker(taskID: id, since: start, shownForStint: saved["shown"] as? Bool ?? false)
    }

    /// Writes the stint (or clears it when nothing is pinned).
    func save(to defaults: UserDefaults) {
        guard let taskID, let since else {
            defaults.removeObject(forKey: Self.defaultsKey)
            return
        }
        defaults.set(["task": taskID.uuidString, "since": since.timeIntervalSince1970, "shown": shownForStint],
                     forKey: Self.defaultsKey)
    }

    /// Feed the current pin on every tick. A different id (or none) starts a new stint.
    mutating func observe(pinnedID: UUID?, now: Date) {
        guard pinnedID != taskID else { return }
        taskID = pinnedID
        since = pinnedID == nil ? nil : now
        shownForStint = false
    }

    mutating func markShown() { shownForStint = true }

    func isDue(now: Date) -> Bool {
        MenuBarQuietLines.longOnTask(since: since, now: now, alreadyShown: shownForStint) != nil
    }
}
