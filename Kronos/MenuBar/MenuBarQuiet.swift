// Kronos/MenuBar/MenuBarQuiet.swift
// Glue between the pure quiet-line rules (MenuBarQuietLines.swift) and the app: reads "now"
// from the injected `KronosClock`, today's calendar events from the coach and the pin from the
// model, and hands the status item and the popover the one string each may show. Never writes
// to the store. The controller ticks it every 60 s; a test moves a fixture clock by hand.
import Foundation
import Observation
import KronosCore

@MainActor
@Observable
final class MenuBarQuiet {
    private let clock: KronosClock
    private(set) var now: Date
    private var tracker: OnTaskTracker
    /// Where the on-task stint is kept across launches; nil keeps it in memory only.
    private let stintDefaults: UserDefaults?
    private(set) var events: [QuietEvent] = []
    /// Snapshot and test seam: events used instead of the coach's calendar blocks.
    var eventsOverride: [QuietEvent]?

    init(clock: KronosClock = SystemClock(), stintDefaults: UserDefaults? = KronosEnv.defaults) {
        self.clock = clock
        self.now = clock.now
        self.stintDefaults = stintDefaults
        self.tracker = stintDefaults.map { OnTaskTracker.restore(from: $0, now: clock.now, calendar: KronosLocale.calendar) }
            ?? OnTaskTracker()
    }

    /// The pinned task's stint start, for the live test.
    var stintStart: Date? { tracker.since }

    /// Move to the clock's current instant, re-read the calendar events and the pin.
    func tick(model: AppModel, events override: [QuietEvent]? = nil) {
        now = clock.now
        events = override ?? eventsOverride ?? model.coach.todaysBlocks.map { QuietEvent(title: $0.event.title, start: $0.event.start, end: $0.event.end) }
        observePin(model.pinnedFocusTaskID)
    }

    /// The pin part of a tick, on its own for a test with no app model.
    func tick(pinnedID: UUID?) {
        now = clock.now
        observePin(pinnedID)
    }

    private func observePin(_ pinnedID: UUID?) {
        let before = tracker
        tracker.observe(pinnedID: pinnedID, now: now)
        if tracker != before { saveStint() }
    }

    /// The single "been at this a while" line is due now (before the popover shows it).
    var isLongOnTaskDue: Bool { tracker.isDue(now: now) }

    private func saveStint() {
        if let stintDefaults { tracker.save(to: stintDefaults) }
    }

    var isOn: Bool { MenuBarPrefs.quietLines }

    /// " · 20 min left" for the bar, or nil.
    var barSuffix: String? {
        guard isOn, case .timeLeft(let minutes)? = MenuBarQuietLines.barSuffix(events: events, now: now) else { return nil }
        return " · " + String(format: String(localized: "menubar.quiet.timeleft"), minutes)
    }

    /// The popover's one quiet line, or nil.
    var popoverText: String? {
        guard isOn else { return nil }
        switch MenuBarQuietLines.popoverLine(events: events, now: now, since: tracker.since, alreadyShown: tracker.shownForStint) {
        case .timeLeft(let minutes)?: return String(format: String(localized: "menubar.quiet.timeleft"), minutes)
        case .next(let title, let start)?:
            return String(format: String(localized: "menubar.quiet.next"), title, Self.timeFormatter.string(from: start))
        case .longOnTask?: return String(localized: "menubar.quiet.long")
        case nil: return nil
        }
    }

    /// Called when the popover showed the long-on-task line, so it is never shown twice.
    func markLongShown() {
        if tracker.isDue(now: now) { tracker.markShown(); saveStint() }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = KronosLocale.calendar
        f.locale = KronosLocale.current
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
}
