// Independent coverage, written by hand from what the user must SEE in Review, exercising
// scenarios beyond the primary CaptureMergeTests suite.
import Foundation
import Testing
@testable import KronosCore

@Suite struct DriverProbeCaptureMergeTests {
    private func row(_ title: String, source: String, notes: String? = nil,
                     edited: Bool = false, ticked: Bool = true, id: UUID = UUID()) -> CaptureMergeRow {
        CaptureMergeRow(id: id,
                        proposal: ProposedTask(title: title, notes: notes, sourceLine: source),
                        isTicked: ticked, isEdited: edited, subtasks: [])
    }
    private func ai(_ title: String, source: String, notes: String? = nil,
                    p: KPriority = .medium, e: KEffort = .s) -> ProposedTask {
        ProposedTask(title: title, priority: p, effort: e, notes: notes, sourceLine: source, isFromAI: true)
    }

    @Test func twoParagraphsKeepEveryTaskAndTheModelsOrder() {
        let p1 = "Call Alex about the invoice and send Maria the contract by Friday."
        let p2 = "Book the meeting room for Tuesday."
        let out = CaptureMerge.merge(
            rows: [row(p1, source: p1), row(p2, source: p2)],
            aiTasks: [ai("Call Alex about the invoice", source: p1),
                      ai("Send Maria the contract", source: p1),
                      ai("Book the meeting room", source: p2)])
        #expect(out.map(\.proposal.title) == ["Call Alex about the invoice", "Send Maria the contract", "Book the meeting room"])
        #expect(out.allSatisfy { $0.proposal.priority == .medium && $0.proposal.effort == .s })
    }

    @Test func croatianDiacriticsParagraphWithTwoTasks() {
        let p = "Nazvati Alexa oko ponude i poslati račun za struju Šimi do četvrtka."
        let out = CaptureMerge.merge(
            rows: [row(p, source: p)],
            aiTasks: [ai("Nazvati Alexa oko ponude", source: p), ai("Poslati račun za struju Šimi", source: p)])
        #expect(out.map(\.proposal.title) == ["Nazvati Alexa oko ponude", "Poslati račun za struju Šimi"])
    }

    /// The same line pasted twice is two rows: nothing lost, nothing multiplied.
    /// KNOWN CEILING: both AI tasks ground in the FIRST identical block and the "no two rows
    /// with the same folded title from one block" rule drops the second, so row 2 stays a plain
    /// (non-AI) row. A literally duplicated line is rare and the cost is "row 2 has no AI
    /// priority/effort", never a lost task. Upgrade path if it ever matters: assign AI tasks to
    /// identical blocks one-to-one, preferring a block with no AI task yet.
    @Test func identicalLinePastedTwiceStaysTwoRows() {
        let line = "Pay the Globex invoice"
        let out = CaptureMerge.merge(
            rows: [row(line, source: line), row(line, source: line)],
            aiTasks: [ai("Pay the Globex invoice", source: line), ai("Pay the Globex invoice", source: line)])
        #expect(out.count == 2)
        #expect(out.map(\.proposal.title) == [line, line])
        #expect(out[0].proposal.isFromAI)
    }

    @Test func editedRowIsNeverReplacedAndItsAITaskDoesNotReappear() {
        let p = "Draft the Initech proposal and review it with Alex."
        let mine = row("MY OWN TITLE", source: p, edited: true)
        let out = CaptureMerge.merge(rows: [mine],
                                     aiTasks: [ai("Draft the Initech proposal", source: p), ai("Review it with Alex", source: p)])
        #expect(out.count == 1)
        #expect(out[0].proposal.title == "MY OWN TITLE")
        #expect(out[0].isEdited)
    }

    /// Review tracks the selected row by id: replacing a row in place must keep ITS id.
    @Test func replacedRowKeepsItsRowIDAndInsertedRowsGetFreshOnes() {
        let p = "Ship the release and tag the build."
        let rid = UUID()
        let out = CaptureMerge.merge(rows: [row(p, source: p, id: rid)],
                                     aiTasks: [ai("Ship the release", source: p), ai("Tag the build", source: p)])
        #expect(out.count == 2)
        #expect(out[0].id == rid)
        #expect(out[1].id != rid)
        #expect(Set(out.map(\.id)).count == 2)
    }

    @Test func emptyAIResultLeavesRowsExactlyAsTheyWere() {
        let rows = [row("One", source: "One"), row("Two", source: "Two", notes: "detail")]
        #expect(CaptureMerge.merge(rows: rows, aiTasks: []) == rows)
    }

    /// The notes-line-repointing defect in a shape not otherwise covered: the notes line is
    /// matched, and a SECOND unrelated row follows. One upgraded row, the other untouched, no
    /// third row.
    @Test func notesRepointedTaskDoesNotDuplicateWithANeighbourRow() {
        let out = CaptureMerge.merge(
            rows: [row("Renew the Acme contract", source: "- Renew the Acme contract", notes: "Legal wants clause 4 removed."),
                   row("Water the plants", source: "- Water the plants")],
            aiTasks: [ai("Renew the Acme contract", source: "Legal wants clause 4 removed.", notes: "Legal wants clause 4 removed.")])
        #expect(out.map(\.proposal.title) == ["Renew the Acme contract", "Water the plants"])
        #expect(out[0].proposal.isFromAI && !out[1].proposal.isFromAI)
    }
}
