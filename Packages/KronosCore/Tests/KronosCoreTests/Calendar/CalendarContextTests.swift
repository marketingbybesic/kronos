import Testing
import Foundation
@testable import KronosCore

@MainActor
struct CalendarContextTests {
    private let zagreb = TimeZone(identifier: "Europe/Zagreb")!

    private func calendar() -> Foundation.Calendar {
        var cal = Foundation.Calendar(identifier: .gregorian)
        cal.timeZone = zagreb
        return cal
    }

    /// Builds a fixed local date/time in Europe/Zagreb, independent of the
    /// machine running the test.
    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min
        return calendar().date(from: c)!
    }

    @Test func nextEventLineIsNilWithoutAccess() async {
        let start = date(2026, 9, 19, 9, 0)
        let event = KCalendarEvent(id: "1", title: "Call with Alex",
                                   start: date(2026, 9, 19, 9, 45), end: date(2026, 9, 19, 10, 0),
                                   isAllDay: false, calendarID: "work")
        let provider = FixtureCalendar(authorizationStatus: .denied, events: [event])
        let selection = FixtureCalendarSelection(["work"])
        let ctx = CalendarContext(provider: provider, selection: selection,
                                  now: { start }, calendar: calendar())
        #expect(await ctx.nextEventLine() == nil)
    }

    @Test func nextEventLineFormatsTimeInLocalCalendar() async {
        let start = date(2026, 9, 19, 13, 45)
        let event = KCalendarEvent(id: "1", title: "Call with Alex",
                                   start: date(2026, 9, 19, 14, 30), end: date(2026, 9, 19, 15, 0),
                                   isAllDay: false, calendarID: "work")
        let provider = FixtureCalendar(events: [event])
        let selection = FixtureCalendarSelection(["work"])
        let ctx = CalendarContext(provider: provider, selection: selection,
                                  now: { start }, calendar: calendar())
        let line = await ctx.nextEventLine(locale: Locale(identifier: "en_US"))
        #expect(line == "Next: Call with Alex at 14:30 (in 45 min)")

        let hrLine = await ctx.nextEventLine(locale: Locale(identifier: "hr_HR"))
        #expect(hrLine == "Sljedeće: Call with Alex u 14:30 (za 45 min)")
    }

    @Test func allDayEventsAreIgnoredForNextEvent() async {
        let start = date(2026, 9, 19, 9, 0)
        let allDay = KCalendarEvent(id: "1", title: "Company holiday",
                                    start: date(2026, 9, 19, 0, 0), end: date(2026, 9, 20, 0, 0),
                                    isAllDay: true, calendarID: "work")
        let timed = KCalendarEvent(id: "2", title: "Standup",
                                   start: date(2026, 9, 19, 10, 0), end: date(2026, 9, 19, 10, 15),
                                   isAllDay: false, calendarID: "work")
        let provider = FixtureCalendar(events: [allDay, timed])
        let selection = FixtureCalendarSelection(["work"])
        let ctx = CalendarContext(provider: provider, selection: selection,
                                  now: { start }, calendar: calendar())
        let line = await ctx.nextEventLine(locale: Locale(identifier: "en_US"))
        #expect(line == "Next: Standup at 10:00 (in 60 min)")
    }

    @Test func deniedAccessNeverThrows() async {
        // requestAccess/authorizationStatus/events must all degrade quietly;
        // FixtureCalendar mirrors EventKitCalendar's non-throwing contract.
        let provider = FixtureCalendar(authorizationStatus: .denied)
        #expect(provider.authorizationStatus == .denied)
        let granted = await provider.requestAccess()
        #expect(granted == .denied)
        let events = await provider.events(from: Date(), to: Date().addingTimeInterval(3600), in: ["work"])
        #expect(events.isEmpty)

        let selection = FixtureCalendarSelection(["work"])
        let ctx = CalendarContext(provider: provider, selection: selection, calendar: calendar())
        let line = await ctx.nextEventLine()
        #expect(line == nil)
        let free = await ctx.freeMinutesUntilNextEvent()
        #expect(free == nil)
    }

    /// Croatia leaves DST on 2026-10-25 at 03:00 -> 02:00 local (CEST -> CET).
    /// An event at 02:30 local, just after the fallback instant, must still
    /// format and rank correctly against a `now` just before it.
    @Test func nextEventAcrossDSTEnd() async {
        let start = date(2026, 10, 25, 1, 0) // still CEST (UTC+2)
        let event = KCalendarEvent(id: "1", title: "Post-DST sync",
                                   start: date(2026, 10, 25, 2, 30), end: date(2026, 10, 25, 3, 0),
                                   isAllDay: false, calendarID: "work")
        let provider = FixtureCalendar(events: [event])
        let selection = FixtureCalendarSelection(["work"])
        let ctx = CalendarContext(provider: provider, selection: selection,
                                  now: { start }, calendar: calendar())
        let line = await ctx.nextEventLine(locale: Locale(identifier: "en_US"))
        #expect(line == "Next: Post-DST sync at 02:30 (in 90 min)")
    }

    @Test func noSelectedCalendarsYieldsNilWithGrantedAccess() async {
        let start = date(2026, 9, 19, 9, 0)
        let event = KCalendarEvent(id: "1", title: "Standup",
                                   start: date(2026, 9, 19, 9, 30), end: date(2026, 9, 19, 9, 45),
                                   isAllDay: false, calendarID: "work")
        let provider = FixtureCalendar(events: [event])
        let selection = FixtureCalendarSelection([]) // nothing picked in Settings
        let ctx = CalendarContext(provider: provider, selection: selection,
                                  now: { start }, calendar: calendar())
        #expect(await ctx.nextEventLine() == nil)
    }

    @Test func pastAndAlreadyEndedEventsAreExcluded() async {
        let start = date(2026, 9, 19, 12, 0)
        let ended = KCalendarEvent(id: "1", title: "Earlier call",
                                   start: date(2026, 9, 19, 10, 0), end: date(2026, 9, 19, 11, 0),
                                   isAllDay: false, calendarID: "work")
        let upcoming = KCalendarEvent(id: "2", title: "Review",
                                      start: date(2026, 9, 19, 13, 0), end: date(2026, 9, 19, 13, 30),
                                      isAllDay: false, calendarID: "work")
        let provider = FixtureCalendar(events: [ended, upcoming])
        let selection = FixtureCalendarSelection(["work"])
        let ctx = CalendarContext(provider: provider, selection: selection,
                                  now: { start }, calendar: calendar())
        let line = await ctx.nextEventLine(locale: Locale(identifier: "en_US"))
        #expect(line == "Next: Review at 13:00 (in 60 min)")
    }

    @Test func freeMinutesUntilNextEventMatchesTheLine() async {
        let start = date(2026, 9, 19, 9, 0)
        let event = KCalendarEvent(id: "1", title: "Focus block",
                                   start: date(2026, 9, 19, 9, 25), end: date(2026, 9, 19, 10, 0),
                                   isAllDay: false, calendarID: "work")
        let provider = FixtureCalendar(events: [event])
        let selection = FixtureCalendarSelection(["work"])
        let ctx = CalendarContext(provider: provider, selection: selection,
                                  now: { start }, calendar: calendar())
        #expect(await ctx.freeMinutesUntilNextEvent() == 25)
    }
}
