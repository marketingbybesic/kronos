import Foundation
import Testing
@testable import KronosCore

/// Notes and dependency edits started on one value and saved after the stored value moved:
/// the other side's change is appended or merged, never lost. Expectations written by hand.
@MainActor
@Suite("ConflictMergeTests")
struct ConflictMergeTests {

    static let header = "— from iPhone —"

    /// (base, mine, theirs, expected text, conflict?)
    static let text: [(String, String, String, String, Bool)] = [
        ("a", "a b", "a", "a b", false),                       // nobody else changed it
        ("a", "a", "a c", "a c", false),                       // only they changed it
        ("a", "a b", "a b", "a b", false),                     // both typed the same
        ("Buy milk", "Buy milk\nand bread", "Buy milk\ncall Ana",
         "Buy milk\nand bread\n\n— from iPhone —\ncall Ana", true),
        ("", "mine", "theirs", "mine\n\n— from iPhone —\ntheirs", true),
        ("old", "new mine", "completely different",
         "new mine\n\n— from iPhone —\ncompletely different", true),
        ("x", "", "x y", "— from iPhone —\ny", true),           // I cleared it, they added
        ("x", "x y z", "x y", "x y z", false),                 // their addition is already in mine
    ]

    @Test func textMergeFollowsTheTable() {
        for (base, mine, theirs, want, conflict) in Self.text {
            let out = TextConflictMerge.merge(base: base, mine: mine, theirs: theirs, header: Self.header)
            #expect(out.text == want, "base=\(base) mine=\(mine) theirs=\(theirs)")
            if case .conflict = out { #expect(conflict) } else { #expect(!conflict) }
        }
    }

    static let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    static let b = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    static let c = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!
    static let d = UUID(uuidString: "00000000-0000-0000-0000-00000000000D")!

    /// (base, mine, theirs, expected)
    static let ids: [([UUID], [UUID], [UUID], [UUID])] = [
        ([a], [a, b], [a], [a, b]),          // I added b
        ([a], [a], [a, c], [a, c]),          // they added c
        ([a], [a, b], [a, c], [a, b, c]),    // both added: both kept
        ([a, b], [b], [a, b, c], [b, c]),    // I removed a, they added c
        ([a, b], [a, b, d], [b], [b, d]),    // they removed a, I added d
        ([], [], [], []),
    ]

    @Test func idMergeFollowsTheTable() {
        for (base, mine, theirs, want) in Self.ids {
            #expect(IDSetMerge.merge(base: base, mine: mine, theirs: theirs) == want)
        }
    }

    /// Through the store: an editor opened on the notes, another writer changed them, the save
    /// keeps both and is one undo step.
    @Test func storeSaveKeepsTheOtherSide() throws {
        let s = try TaskStore(inMemory: true)
        let t = s.create(title: "Shopping", notes: "Buy milk")
        let base = t.notes
        s.updateNoUndo(t.id) { $0.notes = "Buy milk\ncall Ana" }   // the other side
        let depth = s.undoDepth
        let out = s.setNotes(t.id, "Buy milk\nand bread", editBase: base, conflictHeader: Self.header)
        #expect(out == .conflict("Buy milk\nand bread\n\n— from iPhone —\ncall Ana"))
        #expect(s.task(t.id)?.notes == "Buy milk\nand bread\n\n— from iPhone —\ncall Ana")
        #expect(s.undoDepth == depth + 1)
    }

    @Test func storeWaitsOnMergesBothSides() throws {
        let s = try TaskStore(inMemory: true)
        let t = s.create(title: "Ship")
        let x = s.create(title: "Build"), y = s.create(title: "Test"), z = s.create(title: "Sign")
        s.setWaitsOn(t.id, [x.id])
        let base = [x.id]
        s.setWaitsOnNoUndo(t.id, [x.id, z.id])              // the other side added z
        #expect(s.setWaitsOn(t.id, [x.id, y.id], editBase: base))
        #expect(s.task(t.id)?.waitsOn == [x.id, y.id, z.id])
    }
}
