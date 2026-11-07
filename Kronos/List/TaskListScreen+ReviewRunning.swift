// Kronos/List/TaskListScreen+ReviewRunning.swift
// The Today header's own quiet line (Kronos v1.2 Phase 2 slice D4): "N ready for review ·
// M running". Split out as an extension — same 500-line reason TaskListScreen+Parts.swift
// documents, `private` becomes internal access for the same reason — and scoped to `.today`
// at the one call site in TaskListScreen.swift's own header(), so every other list pays
// nothing for the extra ReviewQueue scan and RunStore fetch this line needs. Slice F's own
// Week strip sits BELOW the header row; this line stays IN it.
import SwiftUI
import KronosCore

extension TaskListScreen {
    /// Renders nothing when both counts are 0 — the caller's own `if model.scope == .today`
    /// gate keeps this line, and its cost, out of every other scope entirely.
    @ViewBuilder
    var reviewRunningLine: some View {
        let reviewCount = currentReviewCount
        let runningTasks = LiveRuns.activeRuns()
        if let text = reviewRunningText(reviewCount: reviewCount, runningCount: runningTasks.count) {
            Button(action: { openReviewOrReveal(reviewCount: reviewCount, runningTaskID: runningTasks.first?.taskID) }) {
                Text(text)
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textSecondary)
            }
            .buttonStyle(.plain)
            .uiTestAnchor("list.today.reviewrunning")
        }
    }

    private var currentReviewCount: Int {
        let today = Day.today(calendar: KronosLocale.calendar)
        ReviewSnooze.prune(today: today)
        return ReviewQueue.count(in: model.store.allTasks(), snoozed: ReviewSnooze.table, today: today)
    }

    /// Which sentence to show, or nil for neither — the branch itself is
    /// `AgentTeamSignals.reviewRunningLine` (KronosCore, table-tested); this only formats the
    /// matching localized string.
    func reviewRunningText(reviewCount: Int, runningCount: Int) -> String? {
        switch AgentTeamSignals.reviewRunningLine(reviewCount: reviewCount, runningCount: runningCount) {
        case .both(let review, let running):
            return String(format: String(localized: "today.header.reviewrunning.both"), review, running)
        case .reviewOnly(let review):
            return String(format: String(localized: "today.header.reviewrunning.reviewonly"), review)
        case .runningOnly(let running):
            return String(format: String(localized: "today.header.reviewrunning.runningonly"), running)
        case .none:
            return nil
        }
    }

    /// Something to review wins (it is the person's own queue rotting unseen); otherwise the
    /// click reveals the first running task's row, same `selectedTaskID` pattern every other
    /// "open this task" action in the app uses.
    func openReviewOrReveal(reviewCount: Int, runningTaskID: UUID?) {
        if reviewCount > 0 {
            model.isReviewNextOpen = true
        } else if let runningTaskID {
            model.selectedTaskID = runningTaskID
        }
    }
}
