// Calendar access. EventKit read only, behind
// a protocol so no EventKit type ever reaches CalendarContext or the UI layer.
//
// Deliberately absent (scope-11, do not add): calendarEventID, a calendar
// strip, drag-to-calendar. This file only supplies picker data and the raw
// events CalendarContext reduces into a prompt line.

import Foundation

/// One calendar the user could show tasks against (EventKit's `EKCalendar`,
/// or a synthetic row from `FixtureCalendar`).
public struct KCalendarInfo: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    /// Hex string e.g. "#FF3B30", already normalized by the provider.
    public let colorHex: String
    /// The account/source this calendar belongs to, e.g. "iCloud", "Google".
    public let sourceTitle: String

    public init(id: String, title: String, colorHex: String, sourceTitle: String) {
        self.id = id
        self.title = title
        self.colorHex = colorHex
        self.sourceTitle = sourceTitle
    }
}

/// One calendar event, reduced to what `CalendarContext` needs. No location,
/// no notes, no attendees — Kronos never writes and never shows more than a
/// title and a time.
public struct KCalendarEvent: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public let calendarID: String

    public init(id: String, title: String, start: Date, end: Date,
                isAllDay: Bool, calendarID: String) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.calendarID = calendarID
    }
}

/// Mirrors the three states a caller must branch on. EventKit exposes more
/// (`.notDetermined`, `.restricted`, `.writeOnly`, …) but every non-granted
/// case degrades to the same empty state (tech-stack.md §7), so the protocol
/// collapses them here rather than leaking `EKAuthorizationStatus`.
public enum KCalendarAccess: Sendable, Equatable {
    case notDetermined
    case denied
    case granted
}

/// Read-only calendar access, implemented by `EventKitCalendar` for the app
/// and `FixtureCalendar` for tests and other leaves. No EventKit type appears
/// in this file or in any conforming type's public surface.
@MainActor
public protocol CalendarProviding: AnyObject {
    /// Current authorization state. Never prompts.
    var authorizationStatus: KCalendarAccess { get }

    /// Prompts the user if `.notDetermined`, otherwise returns the current
    /// status without prompting again. Call only from an explicit user
    /// action (Calendars tab, Today strip) — never at launch (tech-stack §7).
    @discardableResult
    func requestAccess() async -> KCalendarAccess

    /// All calendars the user can pick from. Empty when access is not
    /// granted; never throws.
    func calendars() async -> [KCalendarInfo]

    /// Events overlapping `[from, to)` in the given calendars, in any order.
    /// Empty when access is not granted, `calendarIDs` is empty, or nothing
    /// falls in range; never throws.
    func events(from: Date, to: Date, in calendarIDs: [String]) async -> [KCalendarEvent]
}
