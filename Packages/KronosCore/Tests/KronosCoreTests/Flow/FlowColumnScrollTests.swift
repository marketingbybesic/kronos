// Hand-written expectation table for FlowColumnScroll.needsHorizontalScroll
// (Kronos/Flow/FlowColumnsView.swift's scrollAxes delegates here). Values are NOT derived from
// the function under test.
import Testing
@testable import KronosCore

struct FlowColumnScrollTests {
    // Real numbers this mirrors: cardWidth 220, columnGap 24, horizontalPadding 24 (2x Space.x3).
    static let cardWidth = 220.0
    static let columnGap = 24.0
    static let padding = 24.0

    struct Row {
        let name: String
        let columnCount: Int
        let available: Double
        let want: Bool
    }

    static let rows: [Row] = [
        Row(name: "zero columns: never scrolls", columnCount: 0, available: 10, want: false),
        Row(name: "1 column, wide pane: fits, no scroll", columnCount: 1, available: 800, want: false),
        Row(name: "1 column, inspector-narrowed pane (E6's actual bug): does not fit, scrolls",
            columnCount: 1, available: 200, want: true),
        Row(name: "2 columns narrowed by the inspector below their combined width: scrolls",
            columnCount: 2, available: 400, want: true),
        Row(name: "4 columns on a wide window: old count-based rule said no scroll, and it still fits here",
            columnCount: 4, available: 1200, want: false),
        Row(name: "5 columns, content width exactly equals available: inclusive, no scroll",
            columnCount: 5, available: 5 * cardWidth + 4 * columnGap + padding, want: false),
        Row(name: "5 columns, one point narrower than exact: scrolls",
            columnCount: 5, available: 5 * cardWidth + 4 * columnGap + padding - 1, want: true),
        Row(name: "6 columns on a huge monitor: old count-based rule always scrolled past 4; this does not, correctly",
            columnCount: 6, available: 3000, want: false),
    ]

    @Test(arguments: rows.indices)
    func table(_ i: Int) {
        let row = Self.rows[i]
        let got = FlowColumnScroll.needsHorizontalScroll(columnCount: row.columnCount, cardWidth: Self.cardWidth,
                                                          columnGap: Self.columnGap, horizontalPadding: Self.padding,
                                                          available: row.available)
        #expect(got == row.want, "\(row.name): got \(got)")
    }

    /// Positive control (rule 19): a deliberately wrong expectation must fail.
    @Test func breakControl() {
        let got = FlowColumnScroll.needsHorizontalScroll(columnCount: 1, cardWidth: Self.cardWidth,
                                                          columnGap: Self.columnGap, horizontalPadding: Self.padding,
                                                          available: 800)
        #expect(got != true, "control: 1 column in an 800pt pane must not need scroll")
    }
}
