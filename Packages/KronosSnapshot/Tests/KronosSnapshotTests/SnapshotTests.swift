import Testing
import Foundation
@testable import KronosSnapshot

private func uuid(_ n: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
}

private var utc: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}

private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
    utc.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
}

private func item(_ n: Int, title: String = "Task", pinned: Bool = false) -> SnapshotItem {
    SnapshotItem(taskID: uuid(n), title: title, pinned: pinned)
}

private func bigPicker(_ count: Int, titleLength: Int) -> [SnapshotPickerRow] {
    (1...count).map {
        SnapshotPickerRow(id: uuid($0), title: String(repeating: "x", count: titleLength), projectName: String(repeating: "p", count: 40))
    }
}

struct SnapshotBudgetTests {
    // Fixture: 500 picker rows with 200-char titles; builder caps titles to 60 first.
    @Test func overBudgetFixtureIsUnderLimitAndNextIsIntact() throws {
        let next = SnapshotItem(taskID: uuid(9001), title: "The one thing", firstMove: "Open the file", pinned: true)
        let input = SnapshotInput(next: next, shown: (1...12).map { item($0) },
                                  picker: bigPicker(500, titleLength: 200), accentHex: "#b483ff", chroma: 2)
        let snap = SnapshotBuilder.build(input, now: date(2026, 10, 3), calendar: utc)
        let data = try SnapshotBuilder.encode(snap)
        #expect(data.count < 64 * 1024)
        #expect(data.count <= SnapshotLimits.hardLimitBytes)
        let back = SnapshotReader.decode(data)
        guard case .snapshot(let s) = back else { Issue.record("not decodable"); return }
        #expect(s.next == next)
        #expect(s.today.count == 8)
        #expect(!s.pickerIndex.isEmpty)
    }

    // Positive control: without the trim the same fixture is over the limit, so the test above
    // would fail if the trim were removed.
    @Test func positiveControlUntrimmedFixtureIsTooBig() throws {
        let input = SnapshotInput(next: item(1), shown: [item(1)], picker: bigPicker(500, titleLength: 200))
        let snap = SnapshotBuilder.build(input, now: date(2026, 10, 3), calendar: utc)
        let untrimmed = try SnapshotBuilder.makeEncoder().encode(snap)
        #expect(untrimmed.count > 64 * 1024)
    }

    @Test func trimDropsPickerBeforeTouchingNextTodaySession() throws {
        let session = SnapshotSession(sessionID: uuid(7), kind: "focus", taskID: uuid(1), startedAt: date(2026, 10, 3), plannedMinutes: 25, phase: "work")
        let input = SnapshotInput(next: item(1, title: "N"), shown: (1...8).map { item($0, title: "T\($0)") },
                                  picker: bigPicker(500, titleLength: 200), session: session)
        let snap = SnapshotBuilder.build(input, now: date(2026, 10, 3), calendar: utc)
        // A tight limit forces the full trim ladder.
        let data = try SnapshotBuilder.encode(snap, limit: 3_000)
        guard case .snapshot(let s) = SnapshotReader.decode(data) else { Issue.record("not decodable"); return }
        #expect(s.session == session)
        #expect(s.next?.title == "N")
        #expect(s.today.map(\.title) == (1...8).map { "T\($0)" })
        #expect(s.pickerIndex.count < 500)
    }

    @Test func smallSnapshotKeepsEverything() throws {
        let input = SnapshotInput(next: item(1), shown: [item(1), item(2)], picker: bigPicker(20, titleLength: 30))
        let snap = SnapshotBuilder.build(input, now: date(2026, 10, 3), calendar: utc)
        let data = try SnapshotBuilder.encode(snap)
        guard case .snapshot(let s) = SnapshotReader.decode(data) else { Issue.record("not decodable"); return }
        #expect(s.pickerIndex.count == 20)
        #expect(s.pickerIndex.first?.title.count == 30)
    }
}

struct SnapshotCapsTests {
    // Hand-written table: (input length, limit, expected length)
    @Test func titleCapsAre80AndEllipsised() {
        let long = String(repeating: "a", count: 200)
        let snap = SnapshotBuilder.build(SnapshotInput(next: SnapshotItem(taskID: uuid(1), title: long, firstMove: long), shown: []),
                                         now: date(2026, 10, 3), calendar: utc)
        #expect(snap.next?.title.count == 80)
        #expect(snap.next?.title.hasSuffix("\u{2026}") == true)
        #expect(snap.next?.firstMove?.count == 80)
        let short = SnapshotBuilder.build(SnapshotInput(next: item(1, title: "Short"), shown: []), now: date(2026, 10, 3), calendar: utc)
        #expect(short.next?.title == "Short")
    }

    @Test func todayIsFirstEightInShownOrder() {
        let shown = (1...12).map { item($0, title: "R\($0)") }
        let snap = SnapshotBuilder.build(SnapshotInput(next: shown[0], shown: shown), now: date(2026, 10, 3), calendar: utc)
        #expect(snap.today.map(\.title) == ["R1", "R2", "R3", "R4", "R5", "R6", "R7", "R8"])
    }

    @Test func pickerAndSmartViewCaps() {
        let sv = (1...6).map { SnapshotSmartView(id: uuid($0), name: "V\($0)") }
        let snap = SnapshotBuilder.build(SnapshotInput(next: nil, shown: [], picker: bigPicker(600, titleLength: 10), smartViews: sv),
                                         now: date(2026, 10, 3), calendar: utc)
        #expect(snap.pickerIndex.count == 500)
        #expect(snap.pickerIndex[0].projectName.count == 24)
        #expect(snap.smartViews.count == 4)
    }
}

struct SnapshotHeadTests {
    private let a = uuid(1), b = uuid(2), c = uuid(3)

    // Precedence table, hand-written: block, pin, shown head -> expected id and source.
    @Test func precedenceTable() {
        #expect(SnapshotHead.resolve(blockFocus: a, pin: b, shownHead: c) == .init(taskID: a, source: .block))
        #expect(SnapshotHead.resolve(blockFocus: nil, pin: b, shownHead: c) == .init(taskID: b, source: .pin))
        #expect(SnapshotHead.resolve(blockFocus: nil, pin: nil, shownHead: c) == .init(taskID: c, source: .list))
        #expect(SnapshotHead.resolve(blockFocus: nil, pin: nil, shownHead: nil) == nil)
        #expect(SnapshotHead.resolve(blockFocus: nil, pin: b, shownHead: nil)?.pinned == true)
        #expect(SnapshotHead.resolve(blockFocus: nil, pin: nil, shownHead: c)?.pinned == false)
    }
}

struct SnapshotDayTests {
    @Test func dayNumberStepsByOnePerCalendarDay() {
        let d1 = SnapshotDay.number(for: date(2026, 10, 3, 0), calendar: utc)
        let d1late = SnapshotDay.number(for: date(2026, 10, 3, 23), calendar: utc)
        let d2 = SnapshotDay.number(for: date(2026, 10, 4, 0), calendar: utc)
        #expect(d1 == d1late)
        #expect(d2 == d1 + 1)
    }

    // Reader display table with a fake clock.
    @Test func displayRules() throws {
        let made = date(2026, 10, 3, 9)
        let snap = SnapshotBuilder.build(SnapshotInput(next: item(1), shown: [item(1)]), now: made, calendar: utc)
        func shown(_ now: Date) -> SnapshotDisplay { SnapshotReader.display(.snapshot(snap), now: now, calendar: utc) }
        #expect(shown(date(2026, 10, 3, 10)) == .live(snap))
        #expect(shown(date(2026, 10, 4, 0)) == .newDay)
        #expect(shown(date(2026, 10, 3, 23)) == .live(snap))
        #expect(SnapshotReader.display(.missing, now: made, calendar: utc) == .placeholder)
        #expect(SnapshotReader.display(.newerContract(2), now: made, calendar: utc) == .placeholder)
        #expect(SnapshotReader.display(.unreadable, now: made, calendar: utc) == .placeholder)
        // Same day but 25 h old cannot happen within one calendar day except across timezones; check the stale branch directly.
        var old = snap
        old.generatedAt = made.addingTimeInterval(-25 * 3600)
        old.dayNumber = SnapshotDay.number(for: made, calendar: utc)
        #expect(SnapshotReader.display(.snapshot(old), now: made, calendar: utc) == .stale(old))
    }

    @Test func newerContractAndUnknownFields() throws {
        let future = Data(#"{"v":99,"generatedAt":"2026-10-03T09:00:00Z","dayNumber":1,"somethingNew":{"x":1}}"#.utf8)
        #expect(SnapshotReader.decode(future) == .newerContract(99))
        let withExtra = Data(#"{"v":1,"generatedAt":"2026-10-03T09:00:00Z","dayNumber":1,"somethingNew":{"x":1}}"#.utf8)
        guard case .snapshot(let s) = SnapshotReader.decode(withExtra) else { Issue.record("unknown field broke decode"); return }
        #expect(s.today.isEmpty)
        #expect(SnapshotReader.decode(Data("not json".utf8)) == .unreadable)
    }
}

struct SnapshotStoreTests {
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kronos-snap-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func identicalContentWritesOnceAndTimestampDoesNotCount() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = SnapshotStore(directory: dir)
        let input = SnapshotInput(next: item(1), shown: [item(1)])
        let s1 = SnapshotBuilder.build(input, now: date(2026, 10, 3, 9), calendar: utc)
        let s2 = SnapshotBuilder.build(input, now: date(2026, 10, 3, 10), calendar: utc)
        #expect(try store.write(s1) == .written)
        #expect(try store.write(s2) == .unchanged)
        // Positive control: a changed head is written.
        let s3 = SnapshotBuilder.build(SnapshotInput(next: item(2), shown: [item(2)]), now: date(2026, 10, 3, 11), calendar: utc)
        #expect(try store.write(s3) == .written)
    }

    @Test func writeThenReadRoundTripsAndSurvivesAFreshStoreObject() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let snap = SnapshotBuilder.build(SnapshotInput(next: item(1, title: "Round"), shown: [item(1, title: "Round")], accentHex: "#b483ff"),
                                         now: date(2026, 10, 3, 9), calendar: utc)
        try SnapshotStore(directory: dir).write(snap)
        let again = SnapshotStore(directory: dir)
        #expect(again.read() == .snapshot(snap))
        // A fresh producer process writing identical content sees the file and reports unchanged.
        #expect(try again.write(snap) == .unchanged)
        #expect(SnapshotStore(directory: tempDir()).read() == .missing)
    }
}

struct TicketTests {
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kronos-ticket-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func sameTicketAppliedTwiceRunsHandlerOnce() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let inbox = TicketInbox(directory: dir)
        let t = Ticket(id: uuid(5), kind: .complete, payload: ["task": uuid(1).uuidString], createdAt: date(2026, 10, 3), device: "iPhone")
        try inbox.submit(t)
        #expect(inbox.pending() == [t])
        var runs = 0
        #expect(try inbox.apply(t, now: date(2026, 10, 3)) { _ in runs += 1 } == true)
        // The same ticket arrives again (a crash re-delivered the file).
        try inbox.submit(t)
        #expect(try inbox.apply(t, now: date(2026, 10, 3)) { _ in runs += 1 } == false)
        #expect(runs == 1)
        #expect(inbox.pending().isEmpty)
        #expect(inbox.hasApplied(t.id, now: date(2026, 10, 3)))
    }

    // Positive control: two DIFFERENT ids both run.
    @Test func differentIdsBothApply() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let inbox = TicketInbox(directory: dir)
        var runs = 0
        for n in [1, 2] {
            let t = Ticket(id: uuid(n), kind: .snooze, createdAt: date(2026, 10, 3), device: "Watch")
            try inbox.apply(t, now: date(2026, 10, 3)) { _ in runs += 1 }
        }
        #expect(runs == 2)
    }

    @Test func failedHandlerLeavesTicketPendingAndUnrecorded() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let inbox = TicketInbox(directory: dir)
        let t = Ticket(id: uuid(3), kind: .create, createdAt: date(2026, 10, 3), device: "Mac")
        try inbox.submit(t)
        struct Boom: Error {}
        #expect(throws: Boom.self) { try inbox.apply(t, now: date(2026, 10, 3)) { _ in throw Boom() } }
        #expect(inbox.pending() == [t])
        #expect(!inbox.hasApplied(t.id, now: date(2026, 10, 3)))
    }

    @Test func ledgerPrunesAfter30Days() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let inbox = TicketInbox(directory: dir)
        let t = Ticket(id: uuid(4), kind: .pin, createdAt: date(2026, 9, 1), device: "Mac")
        try inbox.apply(t, now: date(2026, 9, 1)) { _ in }
        #expect(inbox.hasApplied(t.id, now: date(2026, 9, 30)))
        #expect(!inbox.hasApplied(t.id, now: date(2026, 10, 2)))
    }

    @Test func pendingIsOldestFirstAndKindsRoundTrip() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let inbox = TicketInbox(directory: dir)
        for (i, kind) in TicketKind.allCases.enumerated() {
            try inbox.submit(Ticket(id: uuid(100 + i), kind: kind, createdAt: date(2026, 10, 3, 20 - i), device: "x"))
        }
        let got = inbox.pending()
        #expect(got.count == 9)
        #expect(got.first?.kind == .pin)          // created at 12:00, the oldest
        #expect(got.last?.kind == .complete)      // created at 20:00, the newest
    }
}
