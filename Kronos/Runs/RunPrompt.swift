// Kronos v1.2 "harness control" (Phase 2 slice B3) / "agent loop": the prompt handed to a
// launched harness. The actual text is built by `RunPromptText` (KronosCore, hermetically
// table-tested); this file's only job is resolving what that pure builder needs from the store —
// subtask order, waits-on titles, the person's feedback history, the previous run's own summary —
// the same split `Kronos/Delivery/WebhookDeliveryController.swift` keeps from its own
// `WebhookDispatcher` (state machine in KronosCore, transport/store access in the app target).

import Foundation
import KronosCore

@MainActor
enum RunPrompt {
    static func build(task: KTask, runID: UUID, store: any TaskStoring, runs: RunStore) -> String {
        let subtasks = (task.children ?? []).sorted { $0.sortIndex < $1.sortIndex }
            .map { RunPromptText.Subtask(title: $0.title, done: $0.status == .done) }
        let waitsOnTitles = task.waitsOn.compactMap { store.task($0)?.title }

        // person feedback: the latest verdict comment (whether the last decision was an accept
        // or a reject — `MCPDispatcher+Review.feedbackNote`'s own rule), the person's full
        // comment history (RunPromptText caps it to the last 5), and the previous run's summary.
        // `runs.start()` already ran before this closure fires (RunSupervisorEngine.launch), so
        // `runs.runs(taskID:)` already includes the brand-new run; skip it by id.
        let result = AgentTaskResult.decode(task.resultJSON)
        let rejectionComment = result?.by == "me" ? result?.verdictComment : nil
        let ownerComments = (AgentContext.decode(task.contextJSON)?.comments ?? [])
            .filter { $0.by == "me" }
            .map(\.text)
        let previousAttemptSummary = runs.runs(taskID: task.id)
            .first { $0.id != runID && !$0.summary.isEmpty }?.summary

        let input = RunPromptText.Input(
            taskID: task.id, runID: runID, title: task.title, firstMove: task.firstMove,
            priority: task.priority, dueDay: task.dueDay, effort: task.effort, notes: task.notes,
            subtasks: subtasks, projectName: task.project?.name, waitsOnTitles: waitsOnTitles,
            rejectionComment: rejectionComment, ownerComments: ownerComments,
            previousAttemptSummary: previousAttemptSummary)
        return RunPromptText.build(input)
    }
}
