import Testing
import Foundation
@testable import KronosCore

/// The entry grammar for a subtask line: a task line minus where it lives. Every expectation is
/// written by hand from the grammar, none is computed by the code under test.
struct ChildEntryTests {
    typealias F = EntryFixture

    private func drafts(_ s: String, pills: [EntryPill] = []) -> [ChildEntryDraft] {
        ChildEntry.drafts(s, pills: pills, directory: F.directory, today: F.today, languages: F.languages)
    }

    struct Row {
        var input: String
        var title: String
        var due: Int? = nil
        var priority: KPriority = .none
        var effort: KEffort? = nil
        var label: String? = nil
        var ignored: String? = nil
    }

    static let rows: [Row] = [
        Row(input: "Book flight !! sutra @finance", title: "Book flight", due: F.today + 1, priority: .medium, label: "finance"),
        Row(input: "Book flight !!! danas *m", title: "Book flight", due: F.today, priority: .high, effort: .m),
        Row(input: "Call Anna @deep work !", title: "Call Anna", priority: .low, label: "deep work"),
        Row(input: "Plain sentence", title: "Plain sentence"),
        Row(input: "  Pad it  ", title: "Pad it"),
        // A project token is never resolved: the word stays in the title and is reported ignored.
        Row(input: "Paint the door #hit list", title: "Paint the door #hit list", ignored: "#hit"),
        Row(input: "#home paint the door", title: "#home paint the door", ignored: "#home"),
        // " > " is not the subtask separator for a child: one line, one title.
        Row(input: "Compare a > b", title: "Compare a > b"),
    ]

    @Test func lineTable() {
        for row in Self.rows {
            let d = drafts(row.input)
            #expect(d.count == 1, "\(row.input)")
            guard let c = d.first else { continue }
            #expect(c.title == row.title, "\(row.input)")
            #expect(c.dueDay == row.due, "\(row.input)")
            #expect(c.priority == row.priority, "\(row.input)")
            #expect(c.effort == row.effort, "\(row.input)")
            #expect(c.labelName == row.label, "\(row.input)")
            #expect(c.ignoredDestination == row.ignored, "\(row.input)")
        }
    }

    @Test func destinationPillsAreDropped() {
        let hit = EntryPill.destination(EntryDestination(kind: .project, name: "Hit list", id: F.hitList.id))
        let d = drafts("Buy stamps", pills: [hit, .priority(.high)])
        #expect(d.count == 1)
        #expect(d.first?.title == "Buy stamps")
        #expect(d.first?.priority == .high)
        #expect(ChildEntry.allows(hit) == false)
        #expect(ChildEntry.allows(.due(5)) == true)
        let r = ChildEntry.resolve(line: "Buy stamps", pills: [hit], directory: F.directory, today: F.today, languages: F.languages)
        #expect(r.destination == nil)
    }

    @Test func linesAreChildrenWithoutOutlineStructure() {
        let d = drafts("First !\n   indented child\n- bulleted\n\nLast sutra")
        #expect(d.map(\.title) == ["First", "indented child", "- bulleted", "Last"])
        #expect(d.map(\.priority) == [.low, .none, .none, .none])
        #expect(d.map(\.dueDay) == [nil, nil, nil, F.today + 1])
        #expect(drafts("   \n \n").isEmpty)
        // A line that is only tokens has no title left: nothing is created for it.
        #expect(drafts("!! sutra").isEmpty)
    }

    // MARK: Store

    @MainActor
    @Test func oneEntryIsOneUndoStep() throws {
        let store = try TaskStore(inMemory: true)
        let proj = store.createProject(name: "Trips", colorHex: "#445566", icon: nil, area: nil)
        let parent = store.create(title: "Plan trip", notes: "", project: proj, status: .todo, priority: .none, dueDay: nil)
        let day = F.today + 1
        let draft = ChildEntryDraft(title: "Book flight", dueDay: day, priority: .medium, effort: .m, labelName: "travel")
        let c = try #require(store.addChildren(to: parent.id, drafts: [draft], undoName: "Add Step").first)

        #expect(c.parentID == parent.id)
        #expect(c.title == "Book flight")
        #expect(c.dueDay == day)
        #expect(c.priority == .medium)
        #expect(c.effort == .m)
        #expect(c.labels?.map(\.name) == ["travel"])
        // Inherited, never moved.
        #expect(c.project?.id == proj.id)
        #expect(store.children(of: parent.id).map(\.title) == ["Book flight"])

        store.undo()
        #expect(store.children(of: parent.id).isEmpty)
        #expect(store.canUndo == true)   // the parent's own creation is still on the stack
        store.undo()
        #expect(store.task(parent.id) == nil)
    }

    @MainActor
    @Test func severalLinesAreOneStepAndNestedParentIsRefused() throws {
        let store = try TaskStore(inMemory: true)
        let parent = store.create(title: "Parent", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
        let made = store.addChildren(to: parent.id, drafts: [ChildEntryDraft(title: "a"), ChildEntryDraft(title: "b", priority: .low)],
                                     undoName: "Add Steps")
        #expect(made.map(\.title) == ["a", "b"])
        store.undo()
        #expect(store.children(of: parent.id).isEmpty)

        // One level only: a child can never get children, and nothing is pushed.
        let child = try #require(store.addChild(to: parent.id, title: "kid", dueDay: nil, priority: .none))
        let depth = store.canUndo
        let none = store.addChildren(to: child.id, drafts: [ChildEntryDraft(title: "grandchild")], undoName: "Add Step")
        #expect(none.isEmpty)
        #expect(store.canUndo == depth)
        #expect(store.children(of: child.id).isEmpty)
        #expect(store.addChildren(to: parent.id, drafts: [], undoName: "Add Step").isEmpty)
    }
}
