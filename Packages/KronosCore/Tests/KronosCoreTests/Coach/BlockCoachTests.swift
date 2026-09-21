import Testing
import Foundation
@testable import KronosCore

struct BlockCoachTests {
    private let zagreb = TimeZone(identifier: "Europe/Zagreb")!

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        var cal = Foundation.Calendar(identifier: .gregorian)
        cal.timeZone = zagreb
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min
        return cal.date(from: c)!
    }

    private let acme = CoachProject(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Acme")
    private let globex = CoachProject(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "Globex")

    @Test func blockCoachSuggestsWhenFocusIsElsewhere() {
        let now = date(2026, 9, 19, 10, 0)
        let event = KCalendarEvent(id: "e1", title: "Acme sync", start: date(2026, 9, 19, 10, 2),
                                   end: date(2026, 9, 19, 11, 0), isAllDay: false, calendarID: "work")
        let suggestion = BlockCoach.suggest(now: now, events: [event], projects: [acme, globex],
                                            keywords: [:], leadMinutes: 5,
                                            focusProjectID: globex.id, answeredEventIDs: [])
        #expect(suggestion?.projectID == acme.id)
        #expect(suggestion?.eventID == "e1")
        #expect(suggestion?.kind == .starting)
    }

    @Test func blockCoachSilentWhenFocusMatches() {
        let now = date(2026, 9, 19, 10, 0)
        let event = KCalendarEvent(id: "e1", title: "Acme sync", start: date(2026, 9, 19, 10, 2),
                                   end: date(2026, 9, 19, 11, 0), isAllDay: false, calendarID: "work")
        let suggestion = BlockCoach.suggest(now: now, events: [event], projects: [acme, globex],
                                            keywords: [:], leadMinutes: 5,
                                            focusProjectID: acme.id, answeredEventIDs: [])
        #expect(suggestion == nil)
    }

    @Test func blockCoachSuggestsOncePerEvent() {
        let now = date(2026, 9, 19, 10, 0)
        let event = KCalendarEvent(id: "e1", title: "Acme sync", start: date(2026, 9, 19, 10, 2),
                                   end: date(2026, 9, 19, 11, 0), isAllDay: false, calendarID: "work")
        // First call (not yet answered) suggests; once the event id is in the
        // answered set — recorded by either Stay or Switch — it goes silent,
        // even though every other input is unchanged.
        let first = BlockCoach.suggest(now: now, events: [event], projects: [acme, globex],
                                       keywords: [:], leadMinutes: 5,
                                       focusProjectID: globex.id, answeredEventIDs: [])
        #expect(first != nil)

        var state = BlockCoachState(day: Day.today())
        state = state.answering("e1")
        let second = BlockCoach.suggest(now: now, events: [event], projects: [acme, globex],
                                        keywords: [:], leadMinutes: 5,
                                        focusProjectID: globex.id, answeredEventIDs: state.answeredEventIDs)
        #expect(second == nil)
    }

    @Test func blockCoachIgnoresAllDayAndShortEvents() {
        let now = date(2026, 9, 19, 10, 0)
        let allDay = KCalendarEvent(id: "e1", title: "Acme offsite", start: date(2026, 9, 19, 0, 0),
                                    end: date(2026, 9, 20, 0, 0), isAllDay: true, calendarID: "work")
        let short = KCalendarEvent(id: "e2", title: "Acme quick ping", start: date(2026, 9, 19, 10, 1),
                                   end: date(2026, 9, 19, 10, 6), isAllDay: false, calendarID: "work")
        let suggestion = BlockCoach.suggest(now: now, events: [allDay, short], projects: [acme, globex],
                                            keywords: [:], leadMinutes: 5,
                                            focusProjectID: globex.id, answeredEventIDs: [])
        #expect(suggestion == nil)
    }

    @Test func longestKeywordWins() {
        // "Acme" alone would match both a generic "Acme" keyword and a more
        // specific "Acme Launch" keyword on the same event title; the longer,
        // more specific keyword must win rather than whichever project is
        // iterated first.
        let acmeGeneric = CoachProject(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, name: "Acme General")
        let acmeLaunch = CoachProject(id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!, name: "Acme Launch")
        let event = KCalendarEvent(id: "e1", title: "Acme Launch review", start: date(2026, 9, 19, 10, 0),
                                   end: date(2026, 9, 19, 11, 0), isAllDay: false, calendarID: "work")
        let match = BlockCoach.matchProject(for: event, projects: [acmeGeneric, acmeLaunch],
                                            keywords: [acmeGeneric.id: ["Acme"], acmeLaunch.id: ["Acme Launch"]])
        #expect(match?.id == acmeLaunch.id)
    }

    @Test func blockCoachSuggestsWhenAlreadyInsideBlockOnWake() {
        // App wakes mid-meeting (no lead-time window applies): still suggests,
        // marked `.insideBlock` rather than `.starting`.
        let now = date(2026, 9, 19, 10, 30)
        let event = KCalendarEvent(id: "e1", title: "Acme sync", start: date(2026, 9, 19, 10, 0),
                                   end: date(2026, 9, 19, 11, 0), isAllDay: false, calendarID: "work")
        let suggestion = BlockCoach.suggest(now: now, events: [event], projects: [acme, globex],
                                            keywords: [:], leadMinutes: 5,
                                            focusProjectID: globex.id, answeredEventIDs: [])
        #expect(suggestion?.kind == .insideBlock)
    }

    @Test func blockCoachStateRollsOverOnDayChange() {
        let state = BlockCoachState(day: 100, answeredEventIDs: ["e1"])
        let sameDay = state.rolledOver(to: 100)
        #expect(sameDay.answeredEventIDs == ["e1"])
        let newDay = state.rolledOver(to: 101)
        #expect(newDay.answeredEventIDs.isEmpty)
    }

    @Test func blockCoachMatchesByProjectNameWithoutKeywords() {
        // No `calendarKeywords` entry at all for either project: matching
        // must still work off the project's own name / a 4+-letter word of
        // it, and off an area name as the widest fallback.
        let launch = CoachProject(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!,
                                   name: "Acme Relaunch")
        let withArea = CoachProject(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000a2")!,
                                     name: "Q4 Planning", areaName: "Globex Ops")

        let byWord = KCalendarEvent(id: "e1", title: "Relaunch kickoff", start: date(2026, 9, 19, 10, 1),
                                    end: date(2026, 9, 19, 11, 0), isAllDay: false, calendarID: "work")
        #expect(BlockCoach.matchProject(for: byWord, projects: [launch, withArea], keywords: [:])?.id == launch.id)

        let byArea = KCalendarEvent(id: "e2", title: "Globex sync", start: date(2026, 9, 19, 10, 1),
                                    end: date(2026, 9, 19, 11, 0), isAllDay: false, calendarID: "work")
        #expect(BlockCoach.matchProject(for: byArea, projects: [launch, withArea], keywords: [:])?.id == withArea.id)
    }

    @Test func blockCoachLearnsFromAnswer() {
        // "Standup" alone matches no project by name/area/keyword, but once the user has
        // answered for this exact title once, the learned map resolves it deterministically
        // from then on — and takes priority over any keyword that might also match.
        let event = KCalendarEvent(id: "e1", title: "Standup", start: date(2026, 9, 19, 10, 0),
                                   end: date(2026, 9, 19, 10, 30), isAllDay: false, calendarID: "work")
        #expect(BlockCoach.matchProject(for: event, projects: [acme, globex], keywords: [:]) == nil)

        var settings = CoachSettings()
        settings.learn(eventTitle: "Standup", projectID: globex.id)
        let matched = BlockCoach.matchProject(for: event, projects: [acme, globex], keywords: [:],
                                              learnedEventTitles: settings.learnedEventTitles)
        #expect(matched?.id == globex.id)

        // Folded lookup: case/diacritic differences in the event title still
        // hit the learned entry.
        let shouted = KCalendarEvent(id: "e2", title: "STANDUP", start: date(2026, 9, 19, 14, 0),
                                     end: date(2026, 9, 19, 14, 30), isAllDay: false, calendarID: "work")
        let matchedShouted = BlockCoach.matchProject(for: shouted, projects: [acme, globex], keywords: [:],
                                                     learnedEventTitles: settings.learnedEventTitles)
        #expect(matchedShouted?.id == globex.id)
    }

    @Test func unmatchedUpcomingEventsExcludesMatchedAndAnswered() {
        let now = date(2026, 9, 19, 10, 0)
        let unmatched = KCalendarEvent(id: "e1", title: "1:1 with Sam", start: date(2026, 9, 19, 10, 1),
                                       end: date(2026, 9, 19, 10, 30), isAllDay: false, calendarID: "work")
        let matched = KCalendarEvent(id: "e2", title: "Acme review", start: date(2026, 9, 19, 10, 1),
                                     end: date(2026, 9, 19, 11, 0), isAllDay: false, calendarID: "work")
        let answered = KCalendarEvent(id: "e3", title: "Random block", start: date(2026, 9, 19, 10, 1),
                                      end: date(2026, 9, 19, 10, 30), isAllDay: false, calendarID: "work")

        let result = BlockCoach.unmatchedUpcomingEvents(now: now, events: [unmatched, matched, answered],
                                                         projects: [acme, globex], keywords: [:], leadMinutes: 5,
                                                         answeredEventIDs: ["e3"])
        #expect(result.map(\.id) == ["e1"])
    }
}
