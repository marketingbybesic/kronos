import Testing
import Foundation
@testable import KronosCore

/// Locked fields (set explicitly by a person or an agent) are never written by triage, and the
/// last fill is recorded so Discard reverts exactly those fields. Expected values are literal.
@MainActor
@Suite("TriageProvenanceTests")
struct TriageProvenanceTests {

    private func result() -> TriageResult {
        TriageResult(project: nil, priority: 3, due: "2026-10-20", depth: .deep,
                     estimateMinutes: 30, energyKind: .admin,
                     firstMove: "Open the invoice folder", labels: ["errand"],
                     rationale: "Short admin block.", proposedRule: nil, effort: .s,
                     reason: nil, version: 1)
    }

    @Test func storedListsParseAndEncodeInCanonicalOrder() {
        #expect(TriageFieldKind.parse("effort,priority,,bogus,priority , labels") == [.priority, .labels, .effort])
        #expect(TriageFieldKind.parse("") == [])
        #expect(TriageFieldKind.encode([.effort, .priority, .effort]) == "priority,effort")
        #expect(TriageFieldKind.encode([TriageFieldKind]()) == "")
    }

    @Test func lockingPersistsAndPushesNoUndoStep() throws {
        let s = try TaskStore(inMemory: true)
        let t = s.create(title: "Pay the invoice", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
        let depth = s.undoDepth
        s.lockField(.priority, on: t.id)
        s.lockField(.due, on: t.id)
        s.lockField(.priority, on: t.id)
        #expect(s.task(t.id)?.lockedFieldsRaw == "priority,due")
        #expect(s.lockedFields(of: t.id) == [.priority, .due])
        #expect(s.undoDepth == depth, "a lock is bookkeeping, not an undoable edit")
        #expect(s.lockedFields(of: UUID()) == [])
    }

    @Test func triageNeverWritesALockedFieldEvenWhenEmpty() throws {
        let s = try TaskStore(inMemory: true)
        let t = s.create(title: "Pay the invoice", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
        // An agent said priority "none" explicitly: that is a choice, not an empty field.
        s.lockField(.priority, on: t.id)
        s.lockField(.firstMove, on: t.id)
        let filled = s.applyTriage(result(), to: t.id)
        let after = try #require(s.task(t.id))
        #expect(after.priorityRaw == 0)
        #expect(after.firstMove == nil)
        #expect(!filled.contains(.priority))
        #expect(!filled.contains(.firstMove))
        #expect(filled == [.due, .depth, .estimateMinutes, .energyKind, .labels, .effort])
        #expect(after.effortRaw == 2)
        #expect(after.dueDay.map(Day.iso) == "2026-10-20")
    }

    @Test func recordingWritesTheModelAndTheFilledFields() throws {
        let s = try TaskStore(inMemory: true)
        let t = s.create(title: "Pay the invoice", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
        let depth = s.undoDepth
        s.recordTriageFill(task: t.id, fields: [.effort, .priority, .firstMove], model: "neighbours")
        let after = try #require(s.task(t.id))
        #expect(after.triageFilledFieldsRaw == "priority,firstMove,effort")
        #expect(after.triageModel == "neighbours")
        #expect(after.triageFilledFields == [.priority, .firstMove, .effort])
        #expect(s.undoDepth == depth, "provenance pushes no undo step")

        s.lockField(.effort, on: t.id)
        s.recordTriageFill(task: t.id, fields: [.effort, .depth], model: "neighbours")
        #expect(s.task(t.id)?.triageFilledFieldsRaw == "depth", "a locked field is never recorded as filled")
    }

    /// Fill, then a title edit, then Discard: the title stays, every filled field is empty again,
    /// a field the user had set before triage stays, the record is gone.
    @Test func discardRevertsExactlyTheFilledFields() throws {
        let s = try TaskStore(inMemory: true)
        let t = s.create(title: "Pay the invoice", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
        s.update(t.id) { $0.depthRaw = KDepth.shallow.rawValue }
        let filled = s.applyTriage(result(), to: t.id)
        #expect(filled == [.priority, .due, .estimateMinutes, .energyKind, .firstMove, .labels, .effort])
        s.recordTriageFill(task: t.id, fields: filled, model: "auto/best-fast")
        s.update(t.id) { $0.title = "Pay the March invoice" }

        let depthBefore = s.undoDepth
        let reverted = s.revertTriageFill(task: t.id)
        #expect(reverted == [.priority, .due, .estimateMinutes, .energyKind, .firstMove, .labels, .effort])
        let after = try #require(s.task(t.id))
        #expect(after.title == "Pay the March invoice")
        #expect(after.depthRaw == 1, "set by the user before triage: untouched")
        #expect(after.priorityRaw == 0)
        #expect(after.dueDay == nil)
        #expect(after.originalDueDay == nil)
        #expect(after.estimateMinutes == nil)
        #expect(after.energyKindRaw == nil)
        #expect(after.firstMove == nil)
        #expect((after.labels ?? []).isEmpty)
        #expect(after.effortRaw == 0)
        #expect(after.triageFilledFieldsRaw == "")
        #expect(after.triageModel == nil)
        #expect(s.undoDepth == depthBefore + 1, "Discard is one undo step")

        s.undo()
        let undone = try #require(s.task(t.id))
        #expect(undone.priorityRaw == 3)
        #expect(undone.firstMove == "Open the invoice folder")
        #expect(undone.title == "Pay the March invoice")
    }

    @Test func aFieldTheUserSetAfterTheFillIsNotReverted() throws {
        let s = try TaskStore(inMemory: true)
        let t = s.create(title: "Pay the invoice", notes: "", project: nil, status: .todo, priority: .none, dueDay: nil)
        let filled = s.applyTriage(result(), to: t.id)
        s.recordTriageFill(task: t.id, fields: filled, model: "auto/best-fast")
        s.update(t.id) { $0.priorityRaw = 4 }
        s.lockField(.priority, on: t.id)
        #expect(s.task(t.id)?.triageFilledFields.contains(.priority) == false)

        let reverted = s.revertTriageFill(task: t.id)
        #expect(!reverted.contains(.priority))
        #expect(s.task(t.id)?.priorityRaw == 4)
        #expect(s.task(t.id)?.effortRaw == 0)
    }

    @Test func discardWithoutARecordDoesNothing() throws {
        let s = try TaskStore(inMemory: true)
        let t = s.create(title: "Pay the invoice", notes: "", project: nil, status: .todo, priority: .high, dueDay: nil)
        let depth = s.undoDepth
        #expect(s.revertTriageFill(task: t.id) == [])
        #expect(s.task(t.id)?.priorityRaw == 3)
        #expect(s.undoDepth == depth)
        #expect(s.revertTriageFill(task: UUID()) == [])
    }
}
