#if os(macOS)
import Testing
import Foundation
@testable import KronosCore

@MainActor
@Suite struct RunStoreTests {

    // MARK: - start / claim

    @Test func startClaimsAnOpenTask() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        let t = rig.store.createNoUndo(title: "Draft the reply")
        let run = try rig.runs.start(taskID: t.id, agent: a, launchedByKronos: false)
        #expect(run.taskID == t.id && run.agentSlug == "codex" && run.stateRaw == "running")
        #expect(rig.runs.activeRun(taskID: t.id)?.id == run.id)
        // positive control: a task with no run has none.
        #expect(rig.runs.activeRun(taskID: UUID()) == nil)
    }

    @Test func aSecondAgentsStartOnAClaimedTaskThrowsClaimed() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex"), b = rig.agent("relay")
        let t = rig.store.createNoUndo(title: "Shared task")
        _ = try rig.runs.start(taskID: t.id, agent: a, launchedByKronos: false)
        #expect(throws: RunError.claimed(by: "codex")) {
            try rig.runs.start(taskID: t.id, agent: b, launchedByKronos: false)
        }
        // positive control: the holder itself is never refused by the same check.
        #expect(throws: Never.self) { try rig.runs.start(taskID: t.id, agent: a, launchedByKronos: false) }
    }

    @Test func theSameAgentsRestartRenewsRatherThanConflicting() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        let t = rig.store.createNoUndo(title: "Task")
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try rig.runs.start(taskID: t.id, agent: a, launchedByKronos: false, lease: 60, now: t0)
        let second = try rig.runs.start(taskID: t.id, agent: a, launchedByKronos: false, lease: 60, now: t0.addingTimeInterval(30))
        #expect(first.id == second.id, "renews the same run, does not create a second one")
        #expect(second.leaseUntil == t0.addingTimeInterval(30 + 60))
    }

    @Test func anExpiredLeaseIsSweptThenAnotherAgentMayStart() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex"), b = rig.agent("relay")
        let t = rig.store.createNoUndo(title: "Task")
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let run = try rig.runs.start(taskID: t.id, agent: a, launchedByKronos: false, lease: 60, now: t0)
        #expect(rig.runs.sweep(now: t0.addingTimeInterval(59)).isEmpty, "not expired yet")
        let after = t0.addingTimeInterval(75)
        let swept = rig.runs.sweep(now: after)
        #expect(swept.map(\.id) == [run.id])
        #expect(rig.runs.run(id: run.id)?.stateRaw == "expired")
        #expect(throws: Never.self) { try rig.runs.start(taskID: t.id, agent: b, launchedByKronos: false, now: after) }
    }

    @Test func aKronosLaunchedRunWithALivePidIsNeverSwept() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        let t = rig.store.createNoUndo(title: "Task")
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let run = try rig.runs.start(taskID: t.id, agent: a, launchedByKronos: true, lease: 60, now: t0)
        run.pid = Int32(ProcessInfo.processInfo.processIdentifier)   // this test process: certainly alive
        #expect(rig.runs.sweep(now: t0.addingTimeInterval(1000)).isEmpty)
        #expect(rig.runs.run(id: run.id)?.stateRaw == "running")
        // positive control: a dead pid on the same Kronos-launched run IS swept.
        run.pid = 0
        #expect(rig.runs.sweep(now: t0.addingTimeInterval(1000)).map(\.id) == [run.id])
    }

    @Test func startOnAPendingTaskIsRefused() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        let t = rig.store.createNoUndo(title: "Proposed")
        rig.store.updateNoUndo(t.id) { $0.reviewRaw = ReviewState.pending }
        #expect(throws: RunError.taskPending) { try rig.runs.start(taskID: t.id, agent: a, launchedByKronos: false) }
        // positive control: once approved, start succeeds.
        rig.store.updateNoUndo(t.id) { $0.reviewRaw = ReviewState.none }
        #expect(throws: Never.self) { try rig.runs.start(taskID: t.id, agent: a, launchedByKronos: false) }
    }

    @Test func startOnAMissingOrDoneTaskIsRefused() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        #expect(throws: RunError.taskMissing) { try rig.runs.start(taskID: UUID(), agent: a, launchedByKronos: false) }
        let t = rig.store.createNoUndo(title: "Finished")
        rig.store.complete(t.id)
        #expect(throws: RunError.taskDone) { try rig.runs.start(taskID: t.id, agent: a, launchedByKronos: false) }
    }

    // MARK: - finish: done

    @Test func doneMovesReviewToAwaitingCheck() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex", scopes: AgentScopes([.read, .propose, .writeOwn]))
        let t = rig.store.createNoUndo(title: "Task")
        let run = try rig.runs.start(taskID: t.id, agent: a, launchedByKronos: false)
        try rig.runs.finish(runID: run.id, agent: a, outcome: .done, summary: "Done it", artifactsAdd: [], handoffTo: nil)
        let task = try #require(rig.store.task(t.id))
        #expect(task.reviewRaw == ReviewState.awaitingCheck)
        #expect(rig.runs.run(id: run.id)?.stateRaw == "done")
        // positive control: without done.trusted it is never silently approved.
        #expect(task.reviewRaw != ReviewState.approved)
    }

    @Test func doneTrustedAutoApproves() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex", scopes: AgentScopes([.read, .propose, .writeOwn, .doneTrusted]))
        let t = rig.store.createNoUndo(title: "Task")
        let run = try rig.runs.start(taskID: t.id, agent: a, launchedByKronos: false)
        try rig.runs.finish(runID: run.id, agent: a, outcome: .done, summary: "Done it", artifactsAdd: [], handoffTo: nil)
        let task = try #require(rig.store.task(t.id))
        #expect(task.reviewRaw == ReviewState.approved && task.status == .done)
    }

    // MARK: - finish: failed

    @Test func failedReopensWithTheNote() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        let t = rig.store.createNoUndo(title: "Task")
        rig.store.updateNoUndo(t.id) { $0.status = .inProgress }
        let run = try rig.runs.start(taskID: t.id, agent: a, launchedByKronos: false)
        try rig.runs.finish(runID: run.id, agent: a, outcome: .failed, summary: "Compiler broke", artifactsAdd: [], handoffTo: nil)
        let task = try #require(rig.store.task(t.id))
        #expect(task.status == .todo)
        #expect(task.notes.contains("Run failed: Compiler broke"))
        #expect(rig.runs.run(id: run.id)?.stateRaw == "failed")
    }

    // MARK: - finish: handoff

    @Test func handoffAssignsTheTargetAndEndsTheRun() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        let b = rig.agent("relay")
        let t = rig.store.createNoUndo(title: "Task")
        let run = try rig.runs.start(taskID: t.id, agent: a, launchedByKronos: false)
        try rig.runs.finish(runID: run.id, agent: a, outcome: .handoff, summary: "Over to you", artifactsAdd: [], handoffTo: "relay")
        let task = try #require(rig.store.task(t.id))
        #expect(task.agentID == b.agentID && task.assigneeRaw == 1)
        #expect(rig.runs.run(id: run.id)?.stateRaw == "handoff")
        #expect(rig.runs.activeRun(taskID: t.id) == nil, "the run ended; it is not still claimed")
    }

    @Test func handoffToAnUnknownSlugThrows() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        let t = rig.store.createNoUndo(title: "Task")
        let run = try rig.runs.start(taskID: t.id, agent: a, launchedByKronos: false)
        #expect(throws: RunError.unknownAgent) {
            try rig.runs.finish(runID: run.id, agent: a, outcome: .handoff, summary: "Over to you", artifactsAdd: [], handoffTo: "nobody")
        }
        // positive control: the failed handoff did not end the run.
        #expect(rig.runs.run(id: run.id)?.stateRaw == "running")
    }

    // MARK: - update

    @Test func updateRenewsTheLeaseAndMergesArtifactsSkippingDuplicates() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        let t = rig.store.createNoUndo(title: "Task")
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let run = try rig.runs.start(taskID: t.id, agent: a, launchedByKronos: false, lease: 60, now: t0)
        let artifact = RunArtifact(kind: "commit", ref: "abc123")
        try rig.runs.update(runID: run.id, agent: a, progress: 0.5, note: "Halfway", artifactsAdd: [artifact], now: t0.addingTimeInterval(10))
        try rig.runs.update(runID: run.id, agent: a, progress: nil, note: nil, artifactsAdd: [artifact], now: t0.addingTimeInterval(20))
        let reloaded = try #require(rig.runs.run(id: run.id))
        #expect(reloaded.progress == 0.5 && reloaded.note == "Halfway")
        #expect(RunArtifact.decodeList(reloaded.artifactsJSON).count == 1, "the duplicate kind+ref was skipped")
        #expect(reloaded.leaseUntil == t0.addingTimeInterval(20 + 1800), "every update renews to now + 1800")
    }

    /// `run_finish`'s own merge must use the SAME kind+ref skip `run_update` does: it reads the
    /// run's CURRENT artifacts (already holding what update added) before merging its own
    /// `artifactsAdd`, never two independent "new since this call" lists that could both let the
    /// same kind+ref through. A different TITLE on the resubmission must not defeat the check —
    /// titles are decoration, kind+ref is the identity, and RunStore.swift's own loop compares
    /// neither more nor less.
    @Test func finishSkipsAnArtifactUpdateAlreadyAddedEvenUnderADifferentTitle() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        let t = rig.store.createNoUndo(title: "Task")
        let run = try rig.runs.start(taskID: t.id, agent: a, launchedByKronos: false)
        try rig.runs.update(runID: run.id, agent: a, progress: nil, note: nil,
                            artifactsAdd: [RunArtifact(kind: "file", ref: "scripts/never-index.sh", title: "wip")])
        try rig.runs.finish(runID: run.id, agent: a, outcome: .done, summary: "Done it", artifactsAdd: [
            RunArtifact(kind: "file", ref: "scripts/never-index.sh", title: "never-index.sh fix"),
            RunArtifact(kind: "commit", ref: "abc123", title: "never-index.sh fix"),
        ], handoffTo: nil)
        let artifacts = RunArtifact.decodeList(try #require(rig.runs.run(id: run.id)).artifactsJSON)
        #expect(artifacts.count == 2, "the file ref update already added is skipped by finish even resubmitted under a new title")
        #expect(artifacts.first { $0.kind == "file" }?.title == "wip", "the ORIGINAL artifact survives untouched; finish's resubmission is dropped, not merged")
        // positive control: a genuinely new kind+ref in the SAME finish call is still appended.
        #expect(artifacts.contains { $0.kind == "commit" && $0.ref == "abc123" })
    }

    @Test func progressIsClampedAndNoteIsTruncated() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        let t = rig.store.createNoUndo(title: "Task")
        let run = try rig.runs.start(taskID: t.id, agent: a, launchedByKronos: false)
        try rig.runs.update(runID: run.id, agent: a, progress: 4.2, note: String(repeating: "x", count: 400), artifactsAdd: [])
        let reloaded = try #require(rig.runs.run(id: run.id))
        #expect(reloaded.progress == 1 && reloaded.note.count == 280)
        // positive control: an in-range value passes through untouched.
        try rig.runs.update(runID: run.id, agent: a, progress: 0.3, note: "short", artifactsAdd: [])
        #expect(rig.runs.run(id: run.id)?.progress == 0.3)
    }

    @Test func updateThrowsNotYoursForAnotherAgent() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex"), b = rig.agent("relay")
        let t = rig.store.createNoUndo(title: "Task")
        let run = try rig.runs.start(taskID: t.id, agent: a, launchedByKronos: false)
        #expect(throws: RunError.notYours) { try rig.runs.update(runID: run.id, agent: b, progress: 0.1, note: nil, artifactsAdd: []) }
        // positive control: the owning agent is not refused.
        #expect(throws: Never.self) { try rig.runs.update(runID: run.id, agent: a, progress: 0.1, note: nil, artifactsAdd: []) }
    }

    @Test func updateOnAFinishedRunThrowsNotActive() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        let t = rig.store.createNoUndo(title: "Task")
        let run = try rig.runs.start(taskID: t.id, agent: a, launchedByKronos: false)
        try rig.runs.finish(runID: run.id, agent: a, outcome: .failed, summary: "stopped early", artifactsAdd: [], handoffTo: nil)
        #expect(throws: RunError.notActive) { try rig.runs.update(runID: run.id, agent: a, progress: 0.9, note: nil, artifactsAdd: []) }
    }

    @Test func aBadArtifactKindThrowsAndWritesNothing() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex")
        let t = rig.store.createNoUndo(title: "Task")
        let run = try rig.runs.start(taskID: t.id, agent: a, launchedByKronos: false)
        #expect(throws: RunError.badArtifact("screenshot")) {
            try rig.runs.update(runID: run.id, agent: a, progress: nil, note: "note", artifactsAdd: [RunArtifact(kind: "screenshot", ref: "x")])
        }
        #expect(rig.runs.run(id: run.id)?.note.isEmpty == true, "the bad artifact refused the whole call, including the note")
        // positive control: a valid kind is accepted.
        try rig.runs.update(runID: run.id, agent: a, progress: nil, note: "note", artifactsAdd: [RunArtifact(kind: "url", ref: "x")])
        #expect(rig.runs.run(id: run.id)?.note == "note")
    }

    // MARK: - stop

    @Test func stopEndsARunningRunRegardlessOfAgentAndDeliversRunStopped() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex", scopes: AgentScopes([.read, .propose, .writeOwn]))
        let t = rig.store.createNoUndo(title: "Task")
        let run = try rig.runs.start(taskID: t.id, agent: a, launchedByKronos: false)
        rig.runs.stop(runID: run.id)
        #expect(rig.runs.run(id: run.id)?.stateRaw == "stopped")
        #expect(rig.runs.activeRun(taskID: t.id) == nil)
        let events = rig.hub.events(for: a, since: 0).events
        #expect(events.contains { $0.verb == ActivityVerb.runStopped }, "the agent hears it lost its claim")
        // positive control: stopping a run that is not running (already stopped) is a silent no-op,
        // not a second delivered event.
        rig.runs.stop(runID: run.id)
        #expect(rig.hub.events(for: a, since: 0).events.filter { $0.verb == ActivityVerb.runStopped }.count == 1)
    }

    // MARK: - events

    @Test func runExpiredIsDeliveredButRunUpdatedIsNot() throws {
        let rig = try AgentRig()
        let a = rig.agent("codex", scopes: AgentScopes([.read, .propose, .writeOwn]))
        let t = rig.store.createNoUndo(title: "Task")
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let run = try rig.runs.start(taskID: t.id, agent: a, launchedByKronos: false, lease: 60, now: t0)
        try rig.runs.update(runID: run.id, agent: a, progress: nil, note: "halfway", artifactsAdd: [], now: t0.addingTimeInterval(10))
        rig.runs.sweep(now: t0.addingTimeInterval(2000))   // past the update's renewed lease (t0+10+1800)
        let events = rig.hub.events(for: a, since: 0).events
        #expect(events.contains { $0.verb == ActivityVerb.runExpired }, "the agent hears it lost its claim")
        #expect(!events.contains { $0.verb == ActivityVerb.runUpdated }, "a heartbeat is never delivered")
        // positive control: run.updated rows do exist in the raw log — it is the delivered
        // filter withholding them, not something that stopped them being written at all.
        #expect(rig.hub.rows().contains { $0.verb == ActivityVerb.runUpdated })
    }
}
#endif
