// The deterministic dread rules: carry of two days or more, and avoidance words in what the
// person typed. Expectations are a hand-written table.

import Testing
import Foundation
@testable import KronosCore

@MainActor
struct DreadRulesTests {

    private struct Case { let title: String; let notes: String; let flagged: Bool }

    private static let words: [Case] = [
        Case(title: "Finally send the invoice", notes: "", flagged: true),
        Case(title: "send the invoice", notes: "should have done this in May", flagged: true),
        Case(title: "Still haven't called the bank", notes: "", flagged: true),
        Case(title: "Still haven’t called the bank", notes: "", flagged: true),
        Case(title: "keep putting off the tax form", notes: "", flagged: true),
        Case(title: "been meaning to email Ana", notes: "", flagged: true),
        Case(title: "Overdue report", notes: "", flagged: true),
        Case(title: "Konačno nazvati banku", notes: "", flagged: true),
        Case(title: "KONAČNO", notes: "", flagged: true),
        Case(title: "Napokon poslati ponudu", notes: "", flagged: true),
        Case(title: "Trebao sam to javiti", notes: "", flagged: true),
        Case(title: "Još nisam odgovorio Karlu", notes: "", flagged: true),
        Case(title: "stalno odgađam knjigovođu", notes: "", flagged: true),
        // Not avoidance language: neighbours that merely contain the letters, or other topics.
        Case(title: "Finalise the deck", notes: "", flagged: false),
        Case(title: "Final review of the deck", notes: "", flagged: false),
        Case(title: "Call the bank", notes: "about the mortgage", flagged: false),
        Case(title: "Buy milk", notes: "", flagged: false),
        Case(title: "Napisati izvješće", notes: "za ponedjeljak", flagged: false),
        Case(title: "Racun za struju", notes: "", flagged: false),
        Case(title: "", notes: "", flagged: false),
    ]

    @Test func avoidanceWordsTable() {
        for c in Self.words {
            #expect(DreadRules.matchesAvoidanceWords(title: c.title, notes: c.notes) == c.flagged,
                    "\(c.title) | \(c.notes)")
        }
    }

    @Test func carryThresholdTable() {
        let rows: [(before: Int, after: Int, reaches: Bool, crosses: Bool)] = [
            (0, 0, false, false), (0, 1, false, false), (1, 2, true, true), (0, 3, true, true),
            (2, 3, true, false), (3, 4, true, false), (1, 1, false, false),
        ]
        for r in rows {
            #expect(DreadRules.carryReachesThreshold(r.after) == r.reaches, "reaches \(r.after)")
            #expect(DreadRules.carryCrossesThreshold(from: r.before, to: r.after) == r.crosses,
                    "crosses \(r.before)->\(r.after)")
        }
    }

    @Test func createFlagsATaskWhoseWordsShowAvoidance() throws {
        let store = try TaskStore(inMemory: true)
        let flagged = store.create(title: "Konačno nazvati knjigovođu")
        let notesOnly = store.create(title: "Invoice", notes: "I should have sent it")
        let plain = store.create(title: "Buy milk")
        #expect(flagged.dread == true)
        #expect(notesOnly.dread == true)
        #expect(plain.dread == false)
    }

    @Test func aCreatedTaskIsFlaggedByUndoRedoToo() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.create(title: "finally pay the tax")
        store.undo()
        #expect(store.task(t.id) == nil, "undo hides the new row")
        store.redo()
        #expect(store.task(t.id)?.dread == true)
    }

    @Test func carryTwoMakesATaskDreadThroughTheSweep() throws {
        let store = try TaskStore(inMemory: true)
        let clock = FixtureClock(day: Day.parseISO("2026-10-10") ?? 0)
        let t = store.create(title: "ordinary", status: .todo, dueDay: clock.today() - 1)
        store.updateNoUndo(t.id) { $0.carryCount = 1 }
        #expect(t.dread == false)
        NightSweep(store: store, clock: clock, defaults: FixtureKeyValueStore()).runIfNeeded()
        #expect(t.carryCount == 2)
        #expect(t.dread == true)
    }
}
