import Testing
import Foundation
@testable import KronosCore

/// The flow the app runs: apply a triage result, record what it filled, later revert exactly that.
@MainActor
struct TriageFillRevertTests {

    private func result() -> TriageResult {
        TriageResult(project: nil, priority: 3, due: nil, depth: .deep, estimateMinutes: 45,
                     energyKind: .creative, firstMove: "Open the draft and read the first section.",
                     labels: [], rationale: "", proposedRule: nil, effort: .m, reason: nil, version: 1)
    }

    private func fillAndRecord(_ store: TaskStore, _ id: UUID, only: Set<TriageFieldKind>? = nil) -> [TriageFieldKind] {
        let filled = store.applyTriage(result(), to: id, only: only)
        store.recordTriageFill(task: id, fields: filled, model: "test-model")
        return filled
    }

    @Test func titleEditThenDiscardKeepsTitleAndClearsFilledFields() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.create(title: "Draft the report")
        let filled = fillAndRecord(store, t.id)
        #expect(filled.contains(.priority) && filled.contains(.effort) && filled.contains(.depth))
        store.update(t.id) { $0.title = "Draft the quarterly report" }

        store.revertTriageFill(task: t.id)

        let after = try #require(store.task(t.id))
        #expect(after.title == "Draft the quarterly report")
        #expect(after.priority == KPriority.none)
        #expect(after.effort == KEffort.none)
        #expect(after.depth == KDepth.unknown)
        #expect(after.estimateMinutes == nil)
        #expect(after.energyKind == nil)
        #expect(after.firstMove == nil)
        #expect(after.triageFilledFieldsRaw.isEmpty)
    }

    @Test func fieldTheOwnerSetBeforeTheFillIsNeverTouched() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.create(title: "Draft the report", notes: "", project: nil, status: .todo,
                             priority: .urgent, dueDay: nil)
        _ = fillAndRecord(store, t.id)
        store.revertTriageFill(task: t.id)
        #expect(store.task(t.id)?.priority == .urgent)
        #expect(store.task(t.id)?.effort == KEffort.none)
    }

    @Test func recordOnlyHoldsWhatWasRestrictedIn() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.create(title: "Draft the report")
        let filled = fillAndRecord(store, t.id, only: [.priority])
        #expect(filled == [.priority])
        #expect(store.task(t.id)?.triageFilledFields == [.priority])
        store.update(t.id) { $0.effortRaw = KEffort.l.rawValue }   // person sets effort after the fill
        store.revertTriageFill(task: t.id)
        #expect(store.task(t.id)?.priority == KPriority.none)
        #expect(store.task(t.id)?.effort == .l)
    }

    // Positive control: without the record, a revert clears nothing, so the cases above can fail.
    @Test func revertWithoutARecordChangesNothing() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.create(title: "Draft the report")
        _ = store.applyTriage(result(), to: t.id)
        let reverted = store.revertTriageFill(task: t.id)
        #expect(reverted.isEmpty)
        #expect(store.task(t.id)?.priority == .high)
    }
}
