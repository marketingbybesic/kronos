import Foundation

/// The arithmetic of dragging a row to a new place in a short vertical list (the project palette in
/// Settings): which row the pointer is over, where the insertion line sits, and the `move(fromOffsets:toOffset:)`
/// argument that puts the row there. Pure, so a table of hand-computed cases can pin it.
public enum PaletteReorder {
    /// The row index the dragged row lands on after the pointer travelled `translation` points down
    /// (negative = up). `pitch` is the distance between two row tops (row height plus gap).
    public static func targetIndex(from index: Int, translation: Double, pitch: Double, count: Int) -> Int {
        guard count > 0, pitch > 0 else { return index }
        let moved = Int((translation / pitch).rounded())
        return min(max(index + moved, 0), count - 1)
    }

    /// The gap the insertion line is drawn in, 0...count (gap `n` sits above row `n`; gap `count` is below the last
    /// row). nil when the row would stay where it is.
    public static func insertionSlot(from index: Int, target: Int) -> Int? {
        if target == index { return nil }
        return target > index ? target + 1 : target
    }

    /// The `toOffset` of `Array.move(fromOffsets:toOffset:)` for a drop in the given gap.
    public static func moveOffset(forSlot slot: Int) -> Int { slot }
}
