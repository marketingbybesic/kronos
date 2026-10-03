import Testing
import Foundation
@testable import KronosCore

/// Delete-area undo re-links its projects by area id, a merge from the Review card is one undo step
/// that brings the proposal back, and a dread flag the person switched off stays off for triage.
@MainActor
@Suite struct Polish2StoreTests {

    // MARK: Delete area (undo re-links projects)

    private func deleteAreaGroup(_ store: TaskStore, _ area: KArea) {
        let projects = store.allProjects(includeArchived: true).filter { $0.area?.id == area.id }
        store.groupedUndo("Delete Area") {
            for p in projects { store.moveProject(p.id, toArea: nil) }
            _ = try? store.deleteArea(area)
        }
    }

    @Test func undoOfDeleteAreaPutsEveryProjectBackUnderTheRestoredArea() throws {
        let store = try TaskStore(inMemory: true)
        let area = store.createArea(name: "Klijenti", colorHex: "#8224E3", icon: "person")
        let areaID = area.id
        let live = store.createProject(name: "Selidba", colorHex: "#8224E3", icon: "circle", area: area)
        let archived = store.createProject(name: "Staro", colorHex: "#8224E3", icon: "circle", area: area)
        store.archiveProject(archived.id)
        let task = store.create(title: "Pakiranje", notes: "", project: live, status: .todo, priority: .none, dueDay: nil)
        let depth = store.undoDepth

        deleteAreaGroup(store, area)
        #expect(store.undoDepth == depth + 1, "one undo step for the whole delete")
        #expect(store.allAreas().isEmpty)
        #expect(live.area == nil && archived.area == nil)
        #expect(store.task(task.id)?.areaID == nil)

        store.undo()
        let restored = try #require(store.allAreas().first { $0.id == areaID })
        #expect(restored !== area, "control: the area came back as a rebuilt row, not the deleted object")
        #expect(live.area === restored, "the project points at the restored row, not the dead one")
        #expect(archived.area === restored)
        #expect(Set((restored.projects ?? []).map(\.id)) == [live.id, archived.id])
        #expect(store.task(task.id)?.areaID == areaID)

        store.redo()
        #expect(store.allAreas().isEmpty)
        #expect(live.area == nil && archived.area == nil)
        #expect(store.task(task.id)?.areaID == nil)

        // A redone group puts its children back as separate steps (TaskStore.groupedUndo), so undoing
        // it again may take more than one press; what matters is where the projects end up.
        var presses = 0
        while live.area == nil || archived.area == nil, presses < 6 { store.undo(); presses += 1 }
        let again = try #require(store.allAreas().first { $0.id == areaID })
        #expect(live.area === again && archived.area === again, "after \(presses) presses live=\(String(describing: live.area?.id)) archived=\(String(describing: archived.area?.id)) again=\(again.id) areas=\(store.allAreas().count)")
    }

    @Test func aProjectEditCanBeUndoneAfterItWasRedone() throws {
        let store = try TaskStore(inMemory: true)
        let p = store.createProject(name: "Selidba", colorHex: "#8224E3", icon: "circle", area: nil)
        store.updateProject(p.id, name: "Novo", colorHex: nil, icon: nil, emoji: nil)
        #expect(p.name == "Novo")
        store.undo()
        #expect(p.name == "Selidba")
        store.redo()
        #expect(p.name == "Novo")
        store.undo()
        #expect(p.name == "Selidba", "the redo armed the undo again")
        store.redo()
        #expect(p.name == "Novo", "and the undo armed the redo again")
    }

    // MARK: Merge from the Review card

    @Test func mergeFromTheReviewCardIsOneStepThatBringsTheProposalBack() throws {
        let rig = try AgentRig()
        let store = rig.store
        let agent = rig.agent("codex")
        let target = store.createNoUndo(title: "Send the contract")
        let proposalID = try rig.taskID(rig.call("create_task", ["title": "Send contract"], as: agent))
        #expect(store.task(proposalID)?.reviewRaw == ReviewState.pending)
        let proposal = ProposedTask(title: "Send contract", firstMove: nil, projectName: nil, priority: .none, effort: .none,
                                    dueDay: nil, notes: nil, subtasks: ["Sign it"], sourceLine: "Send contract")
        let depth = store.undoDepth

        store.groupedUndo("Merge Tasks") {
            store.mergeProposal(proposal, subtasks: proposal.subtasks, into: target.id)
            AgentReview.merge(proposalID, into: target.id, reason: "Merged", store: store)
        }
        #expect(store.undoDepth == depth + 1, "one undo step covers the fold and the close")
        #expect(store.task(target.id)?.orderedSubtasks.map(\.title) == ["Sign it"], "control: the content moved into the task")
        #expect(store.task(proposalID) == nil)
        let closed = try #require(store.taskIncludingDeleted(proposalID))
        let result = try #require(AgentTaskResult.decode(closed.resultJSON))
        #expect(closed.reviewRaw == ReviewState.approved && result.decision == "merge" && result.mergedInto == target.id)

        store.undo()
        #expect(store.task(proposalID)?.reviewRaw == ReviewState.pending, "the proposal is back and waiting")
        #expect(store.task(target.id)?.orderedSubtasks.isEmpty == true, "and the task has its old steps")
    }

    // MARK: Dread lock

    private func triage(dread: Bool?) -> TriageResult {
        TriageResult(project: nil, priority: 2, due: nil, depth: .shallow, estimateMinutes: 15,
                     energyKind: .people, firstMove: "Open the thread with the landlord", labels: [],
                     rationale: "An owed apology.", dread: dread)
    }

    /// locked, model verdict, dread before -> dread after
    private let table: [(locked: Bool, model: Bool?, before: Bool, after: Bool)] = [
        (false, true, false, true),    // control: unlocked, the model says dread: set
        (true, true, false, false),    // switched off by hand: stays off
        (true, true, true, true),      // locked but on: untouched
        (true, nil, false, false),
        (false, nil, false, false),
    ]

    @Test func aDreadFlagSwitchedOffByHandIsNotSetAgainByTriage() throws {
        for row in table {
            let store = try TaskStore(inMemory: true)
            let t = store.create(title: "Write to the landlord")
            store.updateNoUndo(t.id) { $0.dread = row.before }
            if row.locked { store.lockDread(on: t.id) }
            store.applyTriage(triage(dread: row.model), to: t.id)
            #expect(store.task(t.id)?.dread == row.after, "locked=\(row.locked) model=\(String(describing: row.model)) before=\(row.before)")
        }
    }

    @Test func theDreadLockSurvivesFieldLocksAndIsLiftable() throws {
        let store = try TaskStore(inMemory: true)
        let t = store.create(title: "Write to the landlord")
        store.lockDread(on: t.id)
        store.lockField(.priority, on: t.id)
        let task = try #require(store.task(t.id))
        #expect(task.dreadLocked, "a later field lock does not drop the dread lock")
        #expect(task.lockedFields == [.priority], "the dread token is not a field of the triage result")
        store.lockDread(on: t.id)
        #expect(task.lockedFieldsRaw == "priority,dread" || task.lockedFieldsRaw == "dread,priority", "locking twice adds nothing: \(task.lockedFieldsRaw)")
        store.unlockDread(on: t.id)
        #expect(!task.dreadLocked && task.lockedFields == [.priority])
        let depth = store.undoDepth
        store.lockDread(on: t.id)
        #expect(store.undoDepth == depth, "bookkeeping pushes no undo step")
    }
}
