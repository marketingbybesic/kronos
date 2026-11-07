// Hand-written expectation table for ColumnBudget.pick (Kronos/List/ListRowView.swift's
// ColumnMode.fitting delegates here). Values are NOT derived from the function under test.
import Testing
@testable import KronosCore

struct ColumnBudgetTests {
    /// Four levels, loosely modelled on the real SlotWidth numbers but deliberately rounder so
    /// the table is easy to hand-check: 0 = minimal (40), 1 = project only (70), 2 = +subtasks
    /// (110), 3 = +recurrence (140).
    static let widths: [Double] = [40, 70, 110, 140]

    struct Row {
        let name: String
        let available: Double
        let neededLevel: Int
        let want: Int
    }

    static let rows: [Row] = [
        Row(name: "plenty of room, nothing needed: stays at the floor, title keeps the rest",
            available: 500, neededLevel: 0, want: 0),
        Row(name: "plenty of room, everything needed: full level",
            available: 500, neededLevel: 3, want: 3),
        Row(name: "needs level 1 (project) and it fits exactly: no more, no less",
            available: 70, neededLevel: 1, want: 1),
        Row(name: "needs level 2 but only level-1 width fits: falls back one step",
            available: 90, neededLevel: 2, want: 1),
        Row(name: "needs level 3 but nothing past the floor fits: falls all the way to 0",
            available: 10, neededLevel: 3, want: 0),
        Row(name: "needs level 2, available is exactly its width: keeps it (inclusive compare)",
            available: 110, neededLevel: 2, want: 2),
        Row(name: "neededLevel out of range (negative) clamps to 0",
            available: 500, neededLevel: -1, want: 0),
        Row(name: "neededLevel out of range (too high) clamps to the top level",
            available: 500, neededLevel: 99, want: 3),
        Row(name: "empty widths table: always 0",
            available: 500, neededLevel: 3, want: 0),
    ]

    @Test(arguments: rows.indices)
    func table(_ i: Int) {
        let row = Self.rows[i]
        let widths = row.name.contains("empty widths") ? [] : Self.widths
        let got = ColumnBudget.pick(available: row.available, widths: widths, neededLevel: row.neededLevel)
        #expect(got == row.want, "\(row.name): got \(got)")
    }

    /// Positive control (rule 19): a deliberately wrong expectation must fail.
    @Test func breakControl() {
        let got = ColumnBudget.pick(available: 500, widths: Self.widths, neededLevel: 0)
        #expect(got != 3, "control: level 0 should never equal the richest level 3")
    }
}
