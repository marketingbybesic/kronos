// CalendarContext — a small reducer.
// Turns raw provider events into the one line prompts embed
// as {{NEXT_EVENT_OR_NONE}} and into a plain minute count for Impuls.

import Foundation

/// Persists the user's chosen calendar ids. `UserDefaults` conforms directly
/// (see below); tests inject an in-memory fake. Not SwiftData — this is a
/// Settings-scoped preference, not a task-store row.
public protocol CalendarSelectionStoring: AnyObject {
    func selectedCalendarIDs() -> [String]
    func setSelectedCalendarIDs(_ ids: [String])
}

extension UserDefaults: CalendarSelectionStoring {
    private static let key = "kronos.selectedCalendarIDs"
    public func selectedCalendarIDs() -> [String] { stringArray(forKey: Self.key) ?? [] }
    public func setSelectedCalendarIDs(_ ids: [String]) { set(ids, forKey: Self.key) }
}

/// Reduces `CalendarProviding` events into the two things the rest of Core
/// needs: a one-line "what's next" string for AI prompts, and a plain minute
/// count so Impuls can avoid suggesting a task longer than the free gap.
@MainActor
public struct CalendarContext {
    private let provider: CalendarProviding
    private let selection: CalendarSelectionStoring
    private let now: () -> Date
    private let calendar: Calendar
    private let lookAheadSeconds: TimeInterval

    /// - Parameters:
    ///   - lookAheadHours: spec leaves the window unstated; defaults to 8h.
    public init(provider: CalendarProviding,
                selection: CalendarSelectionStoring,
                now: @escaping () -> Date = Date.init,
                calendar: Calendar = .current,
                lookAheadHours: Double = 8) {
        self.provider = provider
        self.selection = selection
        self.now = now
        self.calendar = calendar
        self.lookAheadSeconds = lookAheadHours * 3600
    }

    /// The next timed, not-yet-ended event within the look-ahead window, or
    /// nil when access is missing, nothing is selected, or nothing qualifies.
    private func nextEvent() async -> KCalendarEvent? {
        guard provider.authorizationStatus == .granted else { return nil }
        let ids = selection.selectedCalendarIDs()
        guard !ids.isEmpty else { return nil }
        let start = now()
        let events = await provider.events(from: start, to: start.addingTimeInterval(lookAheadSeconds), in: ids)
        return events
            .filter { !$0.isAllDay && $0.end > start }
            .min { $0.start < $1.start }
    }

    /// e.g. "Next: Call with Alex at 14:30 (in 45 min)" / HR "Sljedeće: …".
    /// Minutes round to the nearest whole minute; an event already in
    /// progress reads "in 0 min" rather than going negative.
    public func nextEventLine(locale: Locale = .current) async -> String? {
        guard let event = await nextEvent() else { return nil }
        let isHR = locale.language.languageCode?.identifier == "hr"
        let tf = DateFormatter()
        tf.calendar = calendar
        tf.timeZone = calendar.timeZone
        tf.locale = Locale(identifier: "en_US_POSIX")
        tf.dateFormat = "HH:mm"
        let time = tf.string(from: event.start)
        let minutesIn = max(0, Int((event.start.timeIntervalSince(now())).rounded() / 60))
        return isHR
            ? "Sljedeće: \(event.title) u \(time) (za \(minutesIn) min)"
            : "Next: \(event.title) at \(time) (in \(minutesIn) min)"
    }

    /// Minutes until the next qualifying event starts, or nil when there is
    /// none in the window — Impuls uses this to cap a suggested task's length.
    public func freeMinutesUntilNextEvent() async -> Int? {
        guard let event = await nextEvent() else { return nil }
        return max(0, Int((event.start.timeIntervalSince(now())).rounded() / 60))
    }
}
