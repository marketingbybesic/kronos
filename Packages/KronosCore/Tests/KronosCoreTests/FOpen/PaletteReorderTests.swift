import Testing
import Foundation
import SwiftUI
@testable import KronosCore

/// Dragging a palette row: target row, insertion gap and the resulting order, against tables worked out by hand.
@Suite struct PaletteReorderTests {

    // 5 rows, pitch 40. (from, translation, expected target)
    private static let targets: [(Int, Double, Int)] = [
        (0, 0, 0), (0, 19, 0), (0, 21, 1), (0, 85, 2), (0, 400, 4),
        (2, -39, 1), (2, -61, 0), (2, -500, 0), (4, 41, 4), (3, 60, 4),
    ]

    @Test func targetRowFollowsThePointerAndStaysInRange() {
        for (from, dy, want) in Self.targets {
            #expect(PaletteReorder.targetIndex(from: from, translation: dy, pitch: 40, count: 5) == want, "from \(from) dy \(dy)")
        }
    }

    // (from, target, expected gap)
    private static let slots: [(Int, Int, Int?)] = [(0, 0, nil), (0, 1, 2), (0, 4, 5), (3, 1, 1), (3, 3, nil), (4, 0, 0), (2, 3, 4)]

    @Test func insertionLineSitsInTheGapTheRowLandsIn() {
        for (from, target, want) in Self.slots {
            #expect(PaletteReorder.insertionSlot(from: from, target: target) == want, "from \(from) target \(target)")
        }
    }

    // The order after a drag, worked out by hand: [a b c d e].
    private static let orders: [(Int, Double, String)] = [
        (0, 85, "bcade"), (0, 400, "bcdea"), (4, -500, "eabcd"), (2, -45, "acbde"), (1, 45, "acbde"), (3, 10, "abcde"),
    ]

    @Test func dropGivesTheHandComputedOrder() {
        for (from, dy, want) in Self.orders {
            var rows = Array("abcde")
            let target = PaletteReorder.targetIndex(from: from, translation: dy, pitch: 40, count: rows.count)
            if let slot = PaletteReorder.insertionSlot(from: from, target: target) {
                rows.move(fromOffsets: IndexSet(integer: from), toOffset: PaletteReorder.moveOffset(forSlot: slot))
            }
            #expect(String(rows) == want, "from \(from) dy \(dy)")
        }
    }

    @Test func degenerateInputsLeaveTheRowAlone() {
        #expect(PaletteReorder.targetIndex(from: 2, translation: 100, pitch: 0, count: 5) == 2)
        #expect(PaletteReorder.targetIndex(from: 0, translation: 100, pitch: 40, count: 0) == 0)
    }
}
