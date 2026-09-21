import Testing
import Foundation
@testable import KronosCore

@Test func wireFormatRoundTrips() {
    let rules: [RecurrenceRule] = [
        .daily(every: 1, anchor: .fromDueDay),
        .daily(every: 3, anchor: .fromCompletionDay),
        .weekly(every: 1, weekdays: [1, 3], anchor: .fromDueDay),
        .weekly(every: 2, weekdays: [5, 7, 1], anchor: .fromCompletionDay),
        .monthly(every: 1, day: 31, anchor: .fromDueDay),
        .monthly(every: 2, day: 15, anchor: .fromCompletionDay),
        .yearly(month: 2, day: 29, anchor: .fromDueDay),
        .everyNDays(5),
    ]
    for rule in rules {
        let wire = rule.wireFormat
        let parsed = RecurrenceRule.parse(wire)
        #expect(parsed == rule, "round trip failed for \(wire)")
        #expect(parsed?.wireFormat == wire)
    }
}

@Test func malformedWireFormatReturnsNil() {
    #expect(RecurrenceRule.parse("") == nil)
    #expect(RecurrenceRule.parse("garbage") == nil)
    #expect(RecurrenceRule.parse("v2;daily;1;anchor=due") == nil)
    #expect(RecurrenceRule.parse("v1;daily;0;anchor=due") == nil)          // every must be >=1
    #expect(RecurrenceRule.parse("v1;daily;1;anchor=whenever") == nil)     // bad anchor
    #expect(RecurrenceRule.parse("v1;weekly;1;days=;anchor=due") == nil)   // empty weekdays
    #expect(RecurrenceRule.parse("v1;weekly;1;days=0,8;anchor=due") == nil) // out of range
    #expect(RecurrenceRule.parse("v1;monthly;1;day=0;anchor=due") == nil)
    #expect(RecurrenceRule.parse("v1;monthly;1;day=32;anchor=due") == nil)
    #expect(RecurrenceRule.parse("v1;yearly;month=13;day=1;anchor=due") == nil)
    #expect(RecurrenceRule.parse("v1;everyNDays;0") == nil)
    #expect(RecurrenceRule.parse("v1;unknownKind;1") == nil)
    #expect(RecurrenceRule.parse("v1;daily;1") == nil)                     // missing anchor field
}

@Test func codableRoundTripsThroughJSON() throws {
    let rule = RecurrenceRule.monthly(every: 1, day: 31, anchor: .fromDueDay)
    let data = try JSONEncoder().encode(rule)
    let decoded = try JSONDecoder().decode(RecurrenceRule.self, from: data)
    #expect(decoded == rule)
}

@Test func descriptionEnglishAndCroatian() {
    #expect(RecurrenceRule.daily(every: 1, anchor: .fromDueDay).description(locale: "en") == "Every day")
    #expect(RecurrenceRule.daily(every: 1, anchor: .fromDueDay).description(locale: "hr") == "Svaki dan")

    #expect(RecurrenceRule.everyNDays(3).description(locale: "hr") == "Svaka 3 dana nakon završetka")
    #expect(RecurrenceRule.everyNDays(5).description(locale: "hr") == "Svakih 5 dana nakon završetka")

    #expect(RecurrenceRule.weekly(every: 1, weekdays: [1, 3], anchor: .fromDueDay).description(locale: "hr")
            == "Svaki tjedan: pon, sri")
    #expect(RecurrenceRule.weekly(every: 1, weekdays: [1, 3], anchor: .fromDueDay).description(locale: "en")
            == "Every week: Mon, Wed")

    #expect(RecurrenceRule.monthly(every: 1, day: 31, anchor: .fromDueDay).description(locale: "hr")
            == "Svaki mjesec 31.")
    #expect(RecurrenceRule.monthly(every: 1, day: 31, anchor: .fromDueDay).description(locale: "en")
            == "Every month on the 31st")

    for s in ["Every day", "Svaki dan", "Svaka 3 dana", "Svakih 5 dana",
              "Svaki tjedan: pon, sri", "Svaki mjesec 31."] {
        #expect(!s.contains("!"))
    }
}
