import Testing
import Foundation
@testable import KronosCore

/// A neighbour vote that is unsure must leave depth, estimate and energy kind EMPTY on the task
/// (never a neutral guess), and triage of a machine-written task must not touch the undo stack.
@MainActor
struct NeighbourVoteFillTests {

    private func example(_ title: String, depth: KDepth, priority: KPriority = .none,
                         effort: KEffort = .none, project: String? = nil) -> TriageExample {
        TriageExample(title: title, projectName: project, priority: priority, effort: effort,
                      depth: depth, hadDeadline: false, open: true, recency: 1)
    }

    /// Runs the same two steps the app runs for a neighbour-sourced result: vote, then apply
    /// only the fields the vote decided.
    private func fill(title: String, context: TriageContext, store: TaskStore) -> (UUID, [TriageFieldKind]) {
        let task = store.create(title: title)
        let result = NeighbourTriage.infer(title: title, notes: "", context: context, today: Day.today())
        let fields = NeighbourTriage.fillableFields(title: title, notes: "", context: context, today: Day.today())
        let filled = store.applyTriage(result, to: task.id, only: fields)
        return (task.id, filled)
    }

    // Hand table: (neighbour depths, expected stored depth after the fill).
    // Weights: 1.0, 0.9, 0.8 ... ; a value needs 2 votes and weight >= 1.5.
    @Test(arguments: [
        // no neighbours: nothing to vote on
        ([KDepth](), KDepth.unknown),
        // one neighbour: a sample of one is not agreement
        ([KDepth.deep], KDepth.unknown),
        // two neighbours disagree
        ([KDepth.deep, KDepth.shallow], KDepth.unknown),
        // untriaged neighbours are no vote for shallow
        ([KDepth.unknown, KDepth.unknown, KDepth.unknown], KDepth.unknown),
        // two agree on deep
        ([KDepth.deep, KDepth.deep], KDepth.deep),
        // two agree on shallow, one unknown ignored
        ([KDepth.unknown, KDepth.shallow, KDepth.shallow], KDepth.shallow),
    ])
    func unsureVoteLeavesDepthEmpty(depths: [KDepth], expected: KDepth) throws {
        let store = try TaskStore(inMemory: true)
        let examples = depths.enumerated().map { example("Task \($0.offset)", depth: $0.element) }
        let (id, _) = fill(title: "Brand new thing", context: TriageContext(examples: examples), store: store)
        let task = try #require(store.task(id))
        #expect(task.depth == expected)
        // estimate and energy kind are never voted on, so they are never invented
        #expect(task.estimateMinutes == nil)
        #expect(task.energyKind == nil)
    }

    @Test func zeroNeighboursFillsNoDepthEstimateOrEnergy() throws {
        let store = try TaskStore(inMemory: true)
        let (id, filled) = fill(title: "Brand new thing", context: .empty, store: store)
        let task = try #require(store.task(id))
        #expect(task.depth == .unknown)
        #expect(task.estimateMinutes == nil)
        #expect(task.energyKind == nil)
        #expect(!filled.contains(.depth))
        #expect(!filled.contains(.estimateMinutes))
        #expect(!filled.contains(.energyKind))
    }

    // Positive control: without the `only:` restriction the placeholder values DO land, which is
    // exactly the defect the restriction removes.
    @Test func withoutTheRestrictionPlaceholdersWouldBeWritten() throws {
        let store = try TaskStore(inMemory: true)
        let task = store.create(title: "Brand new thing")
        let result = NeighbourTriage.infer(title: "Brand new thing", notes: "", context: .empty, today: Day.today())
        store.applyTriage(result, to: task.id)
        let after = try #require(store.task(task.id))
        #expect(after.estimateMinutes == 15)
        #expect(after.energyKind == .admin)
        #expect(after.depth == .shallow)
    }

    @Test func agreedFieldsStillFillAndOthersStayEmpty() throws {
        let store = try TaskStore(inMemory: true)
        let examples = [
            example("Acme invoice 1", depth: .unknown, priority: .high, effort: .s),
            example("Acme invoice 2", depth: .unknown, priority: .high, effort: .s),
        ]
        let (id, filled) = fill(title: "Acme invoice 3", context: TriageContext(examples: examples), store: store)
        let task = try #require(store.task(id))
        #expect(task.priority == .high)
        #expect(task.effort == .s)
        #expect(filled.contains(.priority))
        #expect(filled.contains(.effort))
        #expect(task.depth == .unknown)
        #expect(task.energyKind == nil)
    }

    // MARK: - machine-origin fill leaves the undo stack alone

    @Test func applyTriageWithoutUndoKeepsUndoDepthAndRedo() throws {
        let store = try TaskStore(inMemory: true)
        let task = store.create(title: "Written by an agent")
        let marker = store.create(title: "Owner's own last action")
        store.update(marker.id) { $0.notes = "typed" }
        #expect(store.canUndo)
        let result = TriageResult(project: nil, priority: 3, due: nil, depth: .deep, estimateMinutes: 45,
                                  energyKind: .creative, firstMove: "Open the draft and read the first section.",
                                  labels: [], rationale: "", proposedRule: nil, effort: .m, reason: nil, version: 1)
        let filled = store.applyTriageWithoutUndo(result, to: task.id)
        #expect(filled.contains(.priority))
        #expect(store.task(task.id)?.priority == .high)
        // one undo reverts the OWNER's note edit, not the machine fill
        store.undo()
        #expect(store.task(marker.id)?.notes == "")
        #expect(store.task(task.id)?.priority == .high)
    }

    // Positive control: the undoable path does bury the person's step.
    @Test func plainApplyTriageDoesPushAnUndoStep() throws {
        let store = try TaskStore(inMemory: true)
        let task = store.create(title: "Written by the owner")
        let marker = store.create(title: "Owner's own last action")
        store.update(marker.id) { $0.notes = "typed" }
        let result = TriageResult(project: nil, priority: 3, due: nil, depth: .deep, estimateMinutes: 45,
                                  energyKind: .creative, firstMove: "Open the draft and read the first section.",
                                  labels: [], rationale: "", proposedRule: nil, effort: .m, reason: nil, version: 1)
        store.applyTriage(result, to: task.id)
        store.undo()
        #expect(store.task(marker.id)?.notes == "typed")
        #expect(store.task(task.id)?.priority == KPriority.none)
    }
}
