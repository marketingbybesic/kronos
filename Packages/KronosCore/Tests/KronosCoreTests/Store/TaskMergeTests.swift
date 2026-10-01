import Testing
import Foundation
@testable import KronosCore

/// "Merge tasks": a duplicate title is folded into the existing open task without losing anything.
/// Expectations are hand-written per field; the undo test judges the real store undo stack.
@MainActor
struct TaskMergeTests {

    private func makeStore() throws -> TaskStore { try TaskStore(inMemory: true) }

    private func existing(_ store: TaskStore, title: String = "Send the offer", notes: String = "",
                          due: Int? = nil, priority: KPriority = .none) -> KTask {
        store.create(title: title, notes: notes, project: nil, status: due == nil ? .someday : .todo,
                     priority: priority, dueDay: due)
    }

    @Test func mergeAddsOnlyNewSubtasks() throws {
        let store = try makeStore()
        let t = existing(store)
        store.addSubtasks(["Find the template", "Fill in prices"], to: t.id)
        let proposal = ProposedTask(title: "send the OFFER", sourceLine: "send the OFFER")
        let out = store.mergeProposal(proposal, subtasks: ["find the template", "Attach logo", "attach LOGO", "  "], into: t.id)
        #expect(out?.subtasksAdded == 1)
        #expect(store.task(t.id)?.orderedSubtasks.map(\.title) == ["Find the template", "Fill in prices", "Attach logo"])
    }

    @Test func mergeAppendsNotesWithoutLosingExisting() throws {
        let store = try makeStore()
        let t = existing(store, notes: "Client wants it by Friday")
        let proposal = ProposedTask(title: "Send the offer", notes: "Include the 2026 price list", sourceLine: "x")
        let out = store.mergeProposal(proposal, subtasks: [], into: t.id)
        #expect(out?.notesAppended == true)
        #expect(store.task(t.id)?.notes == "Client wants it by Friday\n\nInclude the 2026 price list")
        // Merging the same note again adds nothing.
        let again = store.mergeProposal(proposal, subtasks: [], into: t.id)
        #expect(again?.notesAppended == false)
        #expect(store.task(t.id)?.notes == "Client wants it by Friday\n\nInclude the 2026 price list")
        // Empty existing notes: the new note becomes the notes, no leading blank lines.
        let blank = existing(store, title: "Other")
        _ = store.mergeProposal(ProposedTask(title: "Other", notes: "Hello", sourceLine: "x"), subtasks: [], into: blank.id)
        #expect(store.task(blank.id)?.notes == "Hello")
    }

    @Test func mergeFillsEmptyFieldsKeepsExisting() throws {
        let store = try makeStore()
        let day = Day.today()
        let a = existing(store, due: day + 2, priority: .high)
        let p1 = ProposedTask(title: "Send the offer", priority: .low, effort: .m, dueDay: day + 9, sourceLine: "x")
        let out1 = store.mergeProposal(p1, subtasks: [], into: a.id)
        #expect(store.task(a.id)?.dueDay == day + 2)          // kept
        #expect(store.task(a.id)?.priority == .high)          // kept
        #expect(store.task(a.id)?.effort == .m)               // filled
        #expect(out1?.filled == ["effort"])
        let b = existing(store, title: "Call Ana")
        let p2 = ProposedTask(title: "Call Ana", priority: .medium, dueDay: day + 3, sourceLine: "x")
        let out2 = store.mergeProposal(p2, subtasks: [], into: b.id)
        #expect(store.task(b.id)?.dueDay == day + 3)
        #expect(store.task(b.id)?.priority == .medium)
        #expect(store.task(b.id)?.status == .todo)            // automatic status rule followed the new due day
        #expect(out2?.filled == ["due", "priority"])
    }

    @Test func mergeUnionsLabels() throws {
        let store = try makeStore()
        let t = existing(store)
        store.addLabel(store.label(named: "Work"), to: t.id)
        let proposal = ProposedTask(title: "Send the offer", labelNames: ["work", "Urgent"], sourceLine: "x")
        let out = store.mergeProposal(proposal, subtasks: [], into: t.id)
        #expect(out?.labelsAdded == 1)
        #expect(Set((store.task(t.id)?.labels ?? []).map { $0.name.lowercased() }) == ["work", "urgent"])
    }

    @Test func mergeIsOneUndoStep() throws {
        let store = try makeStore()
        let t = existing(store, notes: "old")
        store.addSubtasks(["Keep me"], to: t.id)
        let depth = store.undoDepth
        let proposal = ProposedTask(title: "Send the offer", labelNames: ["Work"], effort: .l, notes: "new", sourceLine: "x")
        _ = store.mergeProposal(proposal, subtasks: ["One", "Two"], into: t.id)
        #expect(store.undoDepth == depth + 1)
        #expect(store.task(t.id)?.orderedSubtasks.count == 3)
        store.undo()
        #expect(store.undoDepth == depth)
        #expect(store.task(t.id)?.orderedSubtasks.map(\.title) == ["Keep me"])
        #expect(store.task(t.id)?.notes == "old")
        #expect(store.task(t.id)?.effort == KEffort.none)
        #expect((store.task(t.id)?.labels ?? []).isEmpty)
    }

    @Test func openTaskMatchingTitleIgnoresDoneAndDeleted() throws {
        let store = try makeStore()
        let done = existing(store, title: "Cleanup")
        store.complete(done.id)
        let gone = existing(store, title: "Cleanup")
        store.softDelete(gone.id)
        #expect(store.openTask(matchingTitle: "cleanup") == nil)
        let live = existing(store, title: "Čišćenje")
        #expect(store.openTask(matchingTitle: "  cisenje ")?.id == nil)       // different word: no match
        #expect(store.openTask(matchingTitle: " čišćenje ")?.id == live.id)   // case/space-insensitive
        #expect(store.openTask(matchingTitle: "CISCENJE")?.id == live.id)     // diacritic-insensitive
        #expect(store.openTask(matchingTitle: "   ") == nil)
    }
}
