import Testing
@testable import KronosCore

@Test func dayRoundTrip() {
    let today = Day.today()
    let iso = Day.iso(today)
    #expect(Day.parseISO(iso) == today)
}

@Test func carryDaysZeroWhenNoDue() {
    let t = KTask(title: "x")
    #expect(t.carryDays(today: Day.today()) == 0)
}
