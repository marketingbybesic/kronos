import Testing
import Foundation
@testable import KronosCore

// Hand-written expectation tables for the list drop engine. Every expected value is written out
// from the design (edges insert, the middle needs the 0.6 s hold, a sorted list hides level-0
// order), never computed from the code under test. The row is 40 pt tall: edge bands are
// y < 10 and y > 30, the middle is between.

private let top = 5.0
private let mid = 20.0
private let bot = 35.0
private let rest = 0.0       // no hold yet
private let held = 0.7       // past the 0.6 s hold

private struct ZoneCase {
    let name: String
    let source: DropSource
    let target: DropTargetKind
    var sameFamily = false
    let y: Double
    let hold: Double
    let manual: Bool
    let expected: DropZone
}

private let zoneTable: [ZoneCase] = [
    // task onto task, manual list
    .init(name: "task top edge manual", source: .task, target: .task, y: top, hold: rest, manual: true, expected: .insertAbove),
    .init(name: "task bottom edge manual", source: .task, target: .task, y: bot, hold: rest, manual: true, expected: .insertBelow),
    .init(name: "task centre no hold", source: .task, target: .task, y: mid, hold: rest, manual: true, expected: .none),
    .init(name: "task centre just before hold", source: .task, target: .task, y: mid, hold: 0.59, manual: true, expected: .none),
    .init(name: "task centre at hold", source: .task, target: .task, y: mid, hold: 0.6, manual: true, expected: .nest),
    .init(name: "task centre held", source: .task, target: .task, y: mid, hold: held, manual: true, expected: .nest),
    // task onto task, sorted list: no level-0 order, nest still works
    .init(name: "task top edge sorted", source: .task, target: .task, y: top, hold: held, manual: false, expected: .none),
    .init(name: "task bottom edge sorted", source: .task, target: .task, y: bot, hold: held, manual: false, expected: .none),
    .init(name: "task centre held sorted", source: .task, target: .task, y: mid, hold: held, manual: false, expected: .nest),
    .init(name: "task centre no hold sorted", source: .task, target: .task, y: mid, hold: rest, manual: false, expected: .none),
    // task onto a subtask row: only nest under the parent
    .init(name: "task over subtask top", source: .task, target: .subtask, y: top, hold: held, manual: true, expected: .none),
    .init(name: "task over subtask bottom", source: .task, target: .subtask, y: bot, hold: held, manual: true, expected: .none),
    .init(name: "task over subtask centre no hold", source: .task, target: .subtask, y: mid, hold: rest, manual: true, expected: .none),
    .init(name: "task over subtask centre held", source: .task, target: .subtask, y: mid, hold: held, manual: true, expected: .nest),
    // subtask onto a task row
    .init(name: "subtask top of a task", source: .subtask, target: .task, y: top, hold: rest, manual: true, expected: .insertAbove),
    .init(name: "subtask bottom of a task", source: .subtask, target: .task, y: bot, hold: rest, manual: true, expected: .insertBelow),
    .init(name: "subtask top of a task sorted", source: .subtask, target: .task, y: top, hold: rest, manual: false, expected: .insertAbove),
    .init(name: "subtask centre of another task no hold", source: .subtask, target: .task, y: mid, hold: rest, manual: true, expected: .none),
    .init(name: "subtask centre of another task held", source: .subtask, target: .task, y: mid, hold: held, manual: true, expected: .moveUnder),
    .init(name: "subtask centre of own parent held", source: .subtask, target: .task, sameFamily: true, y: mid, hold: held, manual: true, expected: .none),
    .init(name: "subtask top of own parent", source: .subtask, target: .task, sameFamily: true, y: top, hold: rest, manual: true, expected: .insertAbove),
    // subtask onto a subtask row
    .init(name: "subtask top sibling", source: .subtask, target: .subtask, sameFamily: true, y: top, hold: rest, manual: true, expected: .insertAbove),
    .init(name: "subtask bottom sibling", source: .subtask, target: .subtask, sameFamily: true, y: bot, hold: rest, manual: true, expected: .insertBelow),
    .init(name: "subtask bottom sibling sorted list", source: .subtask, target: .subtask, sameFamily: true, y: bot, hold: rest, manual: false, expected: .insertBelow),
    .init(name: "subtask centre sibling held", source: .subtask, target: .subtask, sameFamily: true, y: mid, hold: held, manual: true, expected: .none),
    .init(name: "subtask top foreign step", source: .subtask, target: .subtask, y: top, hold: rest, manual: true, expected: .insertAbove),
    .init(name: "subtask centre foreign step no hold", source: .subtask, target: .subtask, y: mid, hold: rest, manual: true, expected: .none),
    .init(name: "subtask centre foreign step held", source: .subtask, target: .subtask, y: mid, hold: held, manual: true, expected: .moveUnder),
    // external onto rows
    .init(name: "external top edge", source: .external, target: .task, y: top, hold: rest, manual: true, expected: .insertAbove),
    .init(name: "external bottom edge", source: .external, target: .task, y: bot, hold: rest, manual: true, expected: .insertBelow),
    .init(name: "external top edge sorted", source: .external, target: .task, y: top, hold: rest, manual: false, expected: .insertAbove),
    .init(name: "external centre no hold", source: .external, target: .task, y: mid, hold: rest, manual: true, expected: .none),
    .init(name: "external centre held", source: .external, target: .task, y: mid, hold: held, manual: true, expected: .attachLink),
    .init(name: "external centre held sorted", source: .external, target: .task, y: mid, hold: held, manual: false, expected: .attachLink),
    .init(name: "external over subtask edge", source: .external, target: .subtask, y: top, hold: held, manual: true, expected: .none),
    .init(name: "external over subtask centre no hold", source: .external, target: .subtask, y: mid, hold: rest, manual: true, expected: .none),
    .init(name: "external over subtask centre held", source: .external, target: .subtask, y: mid, hold: held, manual: true, expected: .attachLink),
    // band boundaries on a 40 pt row (edge 10)
    .init(name: "boundary just inside top edge", source: .task, target: .task, y: 9.99, hold: rest, manual: true, expected: .insertAbove),
    .init(name: "boundary start of centre", source: .task, target: .task, y: 10.0, hold: held, manual: true, expected: .nest),
    .init(name: "boundary end of centre", source: .task, target: .task, y: 30.0, hold: held, manual: true, expected: .nest),
    .init(name: "boundary just inside bottom edge", source: .task, target: .task, y: 30.01, hold: rest, manual: true, expected: .insertBelow),
    // pointer outside the row counts as the nearest edge
    .init(name: "pointer above the row", source: .task, target: .task, y: -6, hold: rest, manual: true, expected: .insertAbove),
    .init(name: "pointer below the row", source: .task, target: .task, y: 46, hold: rest, manual: true, expected: .insertBelow),
]

private func runZone(_ c: ZoneCase, hold: Double? = nil, manual: Bool? = nil) -> DropZone {
    DropRules.zone(pointerY: c.y, rowHeight: 40, target: c.target, source: c.source, sameFamily: c.sameFamily,
                   holdSeconds: hold ?? c.hold, isManualSort: manual ?? c.manual)
}

@Suite("Drop zone rules")
struct DropZoneTests {

    @Test("zone table: every combination of source, target, band, hold and sort mode")
    func zoneTableMatches() {
        for c in zoneTable {
            #expect(runZone(c) == c.expected, "\(c.name)")
        }
    }

    @Test("the hold threshold is 0.6 s and lives in one place")
    func holdThreshold() {
        #expect(dropHoldSeconds == 0.6)
        #expect(dropEdgeFraction == 0.25)
    }

    @Test("insertion line: shown for manual level-0 and always for steps, never for a non-insert zone")
    func lineVisibility() {
        #expect(DropRules.showsInsertionLine(zone: .insertAbove, target: .task, isManualSort: true))
        #expect(!DropRules.showsInsertionLine(zone: .insertAbove, target: .task, isManualSort: false))
        #expect(DropRules.showsInsertionLine(zone: .insertBelow, target: .subtask, isManualSort: false))
        #expect(!DropRules.showsInsertionLine(zone: .nest, target: .task, isManualSort: true))
        #expect(!DropRules.showsInsertionLine(zone: .none, target: .subtask, isManualSort: true))
        #expect(!DropRules.showsInsertionLine(zone: .attachLink, target: .task, isManualSort: true))
    }

    // MARK: positive controls: a deliberately broken rule must make the table fail

    @Test("positive control: a rule that ignores the hold is caught by the table")
    func controlIgnoringHoldFails() {
        let mismatches = zoneTable.filter { runZone($0, hold: held) != $0.expected }
        #expect(!mismatches.isEmpty, "the table could not tell a rule without the hold from the real one")
        // And it is specifically the no-hold rows that catch it.
        #expect(mismatches.contains { $0.name == "task centre no hold" })
    }

    @Test("positive control: a rule that treats every list as manual is caught by the table")
    func controlIgnoringSortModeFails() {
        let mismatches = zoneTable.filter { runZone($0, manual: true) != $0.expected }
        #expect(!mismatches.isEmpty)
        #expect(mismatches.contains { $0.name == "task top edge sorted" })
    }

    @Test("positive control: a rule that never holds is caught by the table")
    func controlNeverHoldingFails() {
        let mismatches = zoneTable.filter { runZone($0, hold: 0) != $0.expected }
        #expect(mismatches.contains { $0.name == "task centre held" })
    }
}

@Suite("Drop auto-scroll")
struct DropAutoScrollTests {
    // View 400 tall, bands of 48 at each edge, 18 pt per tick at the very edge, never under 2.
    private let table: [(String, Double, Double)] = [
        ("middle", 200, 0),
        ("just outside the top band", 48, 0),
        ("just outside the bottom band", 352, 0),
        ("top edge", 0, -18),
        ("above the view", -30, -18),
        ("halfway into the top band", 24, -9),
        ("deep in the top band", 47, -2),
        ("bottom edge", 400, 18),
        ("below the view", 430, 18),
        ("halfway into the bottom band", 376, 9),
        ("deep in the bottom band", 353, 2),
    ]

    @Test("step table")
    func stepTable() {
        for (name, y, want) in table {
            #expect(abs(DropAutoScroll.step(pointerY: y, viewHeight: 400) - want) < 0.0001, "\(name)")
        }
    }

    @Test("a view too short for two bands never scrolls")
    func shortView() {
        #expect(DropAutoScroll.step(pointerY: 5, viewHeight: 90) == 0)
        #expect(DropAutoScroll.step(pointerY: 85, viewHeight: 90) == 0)
    }

    @Test("positive control: a fixed speed would fail the halfway rows")
    func controlFixedSpeed() {
        let broken = table.filter { name, y, want in
            let fixed: Double = y < 48 ? -18 : (y > 352 ? 18 : 0)
            return abs(fixed - want) > 0.0001
        }
        #expect(!broken.isEmpty)
    }
}
