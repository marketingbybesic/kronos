import Testing
import Foundation
@testable import KronosCore

/// A field the person or an agent set explicitly is never filled by triage, even when it looks empty.
@MainActor
struct TriageLockedFieldFillTests {

    private func result() -> TriageResult {
        TriageResult(project: nil, priority: 3, due: nil, depth: .deep, estimateMinutes: 45,
                     energyKind: .creative, firstMove: "Open the draft and read the first section.",
                     labels: [], rationale: "", proposedRule: nil, effort: .m, reason: nil, version: 1)
    }

    @Test func lockedPriorityStaysNoneWhileOthersFill() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.create(title: "Agent task")
        store.lockField(.priority, on: t.id)
        #expect(store.lockedFields(of: t.id) == [.priority])
        let filled = store.applyTriage(result(), to: t.id)
        #expect(!filled.contains(.priority))
        #expect(store.task(t.id)?.priority == KPriority.none)
        #expect(filled.contains(.effort))
    }

    // Positive control: unlocked, the same call fills priority.
    @Test func unlockedPriorityIsFilled() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.create(title: "Owner task")
        let filled = store.applyTriage(result(), to: t.id)
        #expect(filled.contains(.priority))
        #expect(store.task(t.id)?.priority == .high)
    }

    @Test func lockedFieldsAreNamedForTheRouterByRawValue() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.create(title: "Agent task")
        store.lockField(.priority, on: t.id)
        store.lockField(.due, on: t.id)
        #expect(Set(store.lockedFields(of: t.id).map(\.rawValue)) == ["priority", "due"])
    }
}
