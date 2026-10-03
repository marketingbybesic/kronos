import Testing
import Foundation
@testable import KronosCore

/// Label rename and colour: hand-written expectations, one undo step per change,
/// no-ops push nothing.
@MainActor
@Suite("LabelEditTests")
struct LabelEditTests {

    private func store(with names: [String]) throws -> (TaskStore, [UUID]) {
        let s = try TaskStore(inMemory: true)
        var ids: [UUID] = []
        for n in names { ids.append(s.label(named: n).id) }
        return (s, ids)
    }

    // (new name, expected result, expected stored name afterwards, pushes an undo step)
    private static let renameTable: [(String, LabelRenameResult, String, Bool)] = [
        ("Errands",        .renamed,   "Errands",  true),
        ("  Errands  ",    .renamed,   "Errands",  true),   // trimmed
        ("work",           .renamed,   "work",     true),   // case-only change is a real rename
        ("Work",           .unchanged, "Work",     false),
        ("   ",            .empty,     "Work",     false),
        ("",               .empty,     "Work",     false),
        ("HOME",           .duplicate, "Work",     false),  // another label folds to the same key
        ("Zurno",          .renamed,   "Zurno",    true),
    ]

    @Test func renameTableMatchesHandWrittenExpectations() throws {
        for (input, result, stored, pushes) in Self.renameTable {
            let (s, ids) = try store(with: ["Work", "Home"])
            let before = s.undoDepth
            let got = s.renameLabel(ids[0], to: input)
            #expect(got == result, "input \(input.debugDescription)")
            #expect(s.label(id: ids[0])?.name == stored, "input \(input.debugDescription)")
            #expect(s.undoDepth - before == (pushes ? 1 : 0), "input \(input.debugDescription)")
        }
    }

    @Test func renameFoldsDiacriticsForTheDuplicateCheck() throws {
        let (s, ids) = try store(with: ["Žurno", "Other"])
        #expect(s.renameLabel(ids[1], to: "zurno") == .duplicate)
        #expect(s.label(id: ids[1])?.name == "Other")
    }

    @Test func renameUnknownLabelIsNotFound() throws {
        let (s, _) = try store(with: ["Work"])
        let before = s.undoDepth
        #expect(s.renameLabel(UUID(), to: "X") == .notFound)
        #expect(s.undoDepth == before)
    }

    @Test func renameIsOneUndoStepAndRedoAlternates() throws {
        let (s, ids) = try store(with: ["Work"])
        let task = s.createNoUndo(title: "T")
        s.addLabel(s.label(id: ids[0])!, to: task.id)
        let depth = s.undoDepth
        s.renameLabel(ids[0], to: "Office")
        #expect(s.undoDepth == depth + 1)
        #expect(s.task(task.id)?.labels?.first?.name == "Office")   // live on the task
        s.undo()
        #expect(s.label(id: ids[0])?.name == "Work")
        #expect(s.undoDepth == depth)
        s.redo()
        #expect(s.label(id: ids[0])?.name == "Office")
        s.undo()
        #expect(s.label(id: ids[0])?.name == "Work")
    }

    // (input, expected stored value or nil for rejected)
    private static let colourTable: [(String, String?)] = [
        ("#5B8DEF", "#5B8DEF"),
        ("5b8def",  "#5B8DEF"),
        (" #5b8DEF ", "#5B8DEF"),
        ("#8B8B93", nil),        // the default colour: already set, no-op
        ("#8b8b93", nil),        // same colour in another case
        ("#12345",  nil),
        ("#12345G", nil),
        ("",        nil),
        ("blue",    nil),
    ]

    @Test func colourTableMatchesHandWrittenExpectations() throws {
        for (input, expected) in Self.colourTable {
            let (s, ids) = try store(with: ["Work"])
            let before = s.undoDepth
            let changed = s.setLabelColor(ids[0], hex: input)
            #expect(changed == (expected != nil), "input \(input.debugDescription)")
            #expect(s.label(id: ids[0])?.colorHex == (expected ?? "#8B8B93"), "input \(input.debugDescription)")
            #expect(s.undoDepth - before == (expected != nil ? 1 : 0), "input \(input.debugDescription)")
        }
    }

    @Test func colourIsOneUndoStepAndRedoAlternates() throws {
        let (s, ids) = try store(with: ["Work"])
        let depth = s.undoDepth
        s.setLabelColor(ids[0], hex: "#F2994A")
        #expect(s.undoDepth == depth + 1)
        s.undo()
        #expect(s.label(id: ids[0])?.colorHex == "#8B8B93")
        s.redo()
        #expect(s.label(id: ids[0])?.colorHex == "#F2994A")
    }

    @Test func labelsListIsNameOrdered() throws {
        let (s, _) = try store(with: ["b", "a", "c"])
        #expect(s.labels().map(\.name) == ["a", "b", "c"])
    }
}
