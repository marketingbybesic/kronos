// Test double for CalendarProviding. Also usable by other leaves (L2's
// RankingEngine/DayPlan consume CalendarContext) so they don't need EventKit
// or a real calendar to exercise their own tests.

import Foundation

/// In-memory `CalendarProviding` with a fixed authorization status and a
/// caller-supplied event list. Never prompts; `requestAccess()` just returns
/// whatever `authorizationStatus` is set to, matching a real store's contract
/// of not re-showing a dialog once a decision exists.
@MainActor
public final class FixtureCalendar: CalendarProviding {
    public var authorizationStatus: KCalendarAccess
    public var stubCalendars: [KCalendarInfo]
    public var stubEvents: [KCalendarEvent]

    public init(authorizationStatus: KCalendarAccess = .granted,
                calendars: [KCalendarInfo] = [],
                events: [KCalendarEvent] = []) {
        self.authorizationStatus = authorizationStatus
        self.stubCalendars = calendars
        self.stubEvents = events
    }

    public func requestAccess() async -> KCalendarAccess { authorizationStatus }

    public func calendars() async -> [KCalendarInfo] {
        authorizationStatus == .granted ? stubCalendars : []
    }

    public func events(from: Date, to: Date, in calendarIDs: [String]) async -> [KCalendarEvent] {
        guard authorizationStatus == .granted else { return [] }
        let ids = Set(calendarIDs)
        return stubEvents.filter { ids.contains($0.calendarID) && $0.start < to && $0.end > from }
    }
}

/// In-memory `CalendarSelectionStoring` for tests — avoids touching real
/// `UserDefaults` from a test target.
public final class FixtureCalendarSelection: CalendarSelectionStoring {
    private var ids: [String]
    public init(_ ids: [String] = []) { self.ids = ids }
    public func selectedCalendarIDs() -> [String] { ids }
    public func setSelectedCalendarIDs(_ ids: [String]) { self.ids = ids }
}
