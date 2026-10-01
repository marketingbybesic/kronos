import Testing
@testable import KronosCore

/// The Shift-Cmd-N "insert subtask marker" rule, with hand-written expectations. Positive control:
/// every inserted marker is fed back through the real `TaskOutline.parse`.
struct SubtaskMarkerTests {

    @Test func markerAtEndOfWordGetsSpacesOnBothSides() {
        let r = SubtaskMarker.insert(into: "Prepare the offer", caret: 17)
        #expect(r.text == "Prepare the offer > ")
        #expect(r.caret == 20)
    }

    @Test func markerOnEmptyLineIsBullet() {
        #expect(SubtaskMarker.insert(into: "Prepare the offer\n", caret: 18).text == "Prepare the offer\n> ")
        #expect(SubtaskMarker.insert(into: "", caret: 0).text == "> ")
        #expect(SubtaskMarker.insert(into: "Plan\n\t", caret: 6).text == "Plan\n\t> ")
    }

    @Test func markerAfterSpaceDoesNotDoubleSpace() {
        #expect(SubtaskMarker.insert(into: "Prepare the offer ", caret: 18).text == "Prepare the offer > ")
        // Caret in the middle, space already behind it: no second space after the marker.
        let mid = SubtaskMarker.insert(into: "Plan  find", caret: 5)
        #expect(mid.text == "Plan > find")
        #expect(!mid.text.contains(">  >"))
        // A caret clamped past the end behaves like the end.
        #expect(SubtaskMarker.insert(into: "x", caret: 99).text == "x > ")
    }

    @Test func insertedMarkerParsesAsSubtask() {
        let inline = SubtaskMarker.insert(into: "Prepare the offer", caret: 17).text + "find the template"
        #expect(TaskOutline.parse(inline) == [TaskOutline.Item(line: "Prepare the offer", subtasks: ["find the template"])])
        let bullet = SubtaskMarker.insert(into: "Prepare the offer\n", caret: 18).text + "fill in prices"
        #expect(TaskOutline.parse(bullet) == [TaskOutline.Item(line: "Prepare the offer", subtasks: ["fill in prices"])])
        // Negative control: the same text without the marker is two tasks, not a subtask.
        #expect(TaskOutline.parse("Prepare the offer\nfill in prices").count == 2)
    }
}
