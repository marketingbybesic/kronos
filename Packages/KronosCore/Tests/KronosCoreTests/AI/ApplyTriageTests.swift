import Testing
import Foundation
@testable import KronosCore

/// `TaskStoring.applyTriage` — fills only empty fields, one undo step.
@MainActor
struct ApplyTriageTests {

    private func makeStore() throws -> TaskStore { try TaskStore(inMemory: true) }

    private func fullResult(project: String? = nil) -> TriageResult {
        TriageResult(project: project, priority: 3, due: "2026-09-25", depth: .deep,
                    estimateMinutes: 45, energyKind: .creative,
                    firstMove: "Open Figma and duplicate the frame.", labels: ["design"],
                    rationale: "Needs a quiet block.", proposedRule: nil, effort: .m,
                    reason: "Like 2 similar tasks", version: 1)
    }

    // MARK: - Required gate test: applyTriageFillsOnlyEmptyFields

    @Test func applyTriageFillsOnlyEmptyFields() throws {
        let store = try makeStore()
        let t = store.create(title: "Design the onboarding screen", notes: "", project: nil,
                             status: .todo, priority: .urgent, dueDay: nil)
        // The user already set priority explicitly; everything else is empty.
        let filled = store.applyTriage(fullResult(), to: t.id)

        let after = store.task(t.id)!
        #expect(after.priority == .urgent)          // untouched: was not empty
        #expect(!filled.contains(.priority))
        #expect(after.depth == .deep)                // filled: was .unknown
        #expect(filled.contains(.depth))
        #expect(after.effort == .m)
        #expect(filled.contains(.effort))
        #expect(after.dueDay == Day.parseISO("2026-09-25"))
        #expect(filled.contains(.due))
        #expect(after.firstMove == "Open Figma and duplicate the frame.")
        #expect(filled.contains(.firstMove))
        #expect(after.needsTriage == false)
    }

    @Test func applyTriageRespectsAllowedFields() throws {
        let store = try makeStore()
        let t = store.create(title: "Design the onboarding screen")
        let filled = store.applyTriage(fullResult(), to: t.id, only: [.priority, .firstMove])
        let after = store.task(t.id)!
        #expect(Set(filled) == [.priority, .firstMove])
        #expect(after.priority == .high)
        #expect(after.depth == .unknown, "depth was not allowed")
        #expect(after.dueDay == nil, "deadline was not allowed")
        #expect(after.effort == .none, "effort was not allowed")
    }

    @Test func applyTriageNeverOverwritesAnyNonEmptyField() throws {
        let store = try makeStore()
        let t = store.create(title: "T", notes: "", project: nil, status: .todo,
                             priority: .low, dueDay: Day.today() + 1)
        store.setDepth(t.id, .shallow)
        store.setEffort(t.id, .xs)
        store.setFirstMove(t.id, "Already set")

        // Only estimateMinutes, energyKind and labels are still empty on this
        // task; the rest (priority, due, depth, effort, firstMove) were set
        // explicitly and must survive untouched.
        let filled = store.applyTriage(fullResult(), to: t.id)
        #expect(!filled.contains(.priority))
        #expect(!filled.contains(.due))
        #expect(!filled.contains(.depth))
        #expect(!filled.contains(.effort))
        #expect(!filled.contains(.firstMove))

        let after = store.task(t.id)!
        #expect(after.priority == .low)
        #expect(after.dueDay == Day.today() + 1)
        #expect(after.depth == .shallow)
        #expect(after.effort == .xs)
        #expect(after.firstMove == "Already set")
    }

    @Test func applyTriageOnlyMatchesAnExistingProjectByName() throws {
        let store = try makeStore()
        let acme = store.createProject(name: "Acme", colorHex: "#000000", icon: nil, area: nil)
        let t = store.create(title: "T", notes: "", project: nil, status: .todo,
                             priority: .none, dueDay: nil)

        let filledUnknown = store.applyTriage(fullResult(project: "Ghost Project"), to: t.id)
        #expect(!filledUnknown.contains(.project))
        #expect(store.task(t.id)?.project == nil)

        let filledKnown = store.applyTriage(fullResult(project: "acme"), to: t.id)   // case-insensitive
        #expect(filledKnown.contains(.project))
        #expect(store.task(t.id)?.project?.id == acme.id)
    }

    // MARK: - Required gate test: applyTriageIsOneUndoStep

    @Test func applyTriageIsOneUndoStep() throws {
        let store = try makeStore()
        let t = store.create(title: "T", notes: "", project: nil, status: .todo,
                             priority: .none, dueDay: nil)
        // Creation already pushed one undo step; applyTriage must push
        // exactly one more, however many fields it fills.
        store.applyTriage(fullResult(), to: t.id)

        store.undo()   // reverses triage as ONE action...
        let afterOneUndo = store.task(t.id)!
        #expect(afterOneUndo.depth == .unknown)
        #expect(afterOneUndo.firstMove == nil)
        #expect(afterOneUndo.effort == .none)
        #expect(afterOneUndo.needsTriage == true)
        #expect(afterOneUndo.title == "T")   // the row itself is still here: undo #1 did not reach creation

        store.undo()   // ...and the SECOND undo reaches the creation, soft-deleting the row.
        #expect(store.task(t.id) == nil)

        store.redo()
        #expect(store.task(t.id) != nil)
        store.redo()
        #expect(store.task(t.id)?.depth == .deep)   // redo restores the whole triage step together
    }

    @Test func applyTriageReturnsEmptyForAMissingTask() throws {
        let store = try makeStore()
        let filled = store.applyTriage(fullResult(), to: UUID())
        #expect(filled.isEmpty)
    }
}
