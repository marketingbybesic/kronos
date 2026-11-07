// Kronos/Projects/ProjectHeaderStrip.swift
// Plan v1.2 Phase 2, F1: one line at the top of a project's List and Flow — progress, up to
// three unblocked ("can start") titles, how many open tasks are blocked, how many are awaiting
// the person's review, and the nearest open deadline. No charts: every value is a plain icon plus
// a number, or plain words.
//
// Mounted by `TaskListScreen.swift` for `.project` scope (the List side). Flow (slice E) mounts
// it at the top of `FlowScreen` itself — this file does not depend on Flow, so that wiring is a
// one-line addition on Flow's side; see the slice F report for the exact call.
import SwiftUI
import KronosCore

struct ProjectHeaderStrip: View {
    @Bindable var model: AppModel
    let projectID: UUID

    private var tasks: [KTask] { model.store.allTasks().filter { $0.projectID == projectID } }
    private var metrics: ProjectInsights.HeaderMetrics {
        ProjectInsights.headerMetrics(tasks: tasks, today: Day.today())
    }

    var body: some View {
        let m = metrics
        if m.totalCount > 0 {
            HStack(spacing: Space.x4) {
                progress(m)
                if !m.canStart.isEmpty { canStartChips(m) }
                if m.blockedCount > 0 {
                    stat(icon: "link", value: m.blockedCount,
                        text: String(format: String(localized: "projects.header.blocked.a11y"), m.blockedCount))
                }
                if m.readyForReviewCount > 0 {
                    stat(icon: "checkmark.seal", value: m.readyForReviewCount,
                        text: String(format: String(localized: "projects.header.ready.a11y"), m.readyForReviewCount))
                }
                if let due = m.nearestDueDay {
                    dueStat(due)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.x4)
            .padding(.vertical, Space.x2)
            .uiTestAnchor("project.header.strip")
        }
    }

    private func progress(_ m: ProjectInsights.HeaderMetrics) -> some View {
        Text(String(format: String(localized: "list.subtask.progress.n_of_m"), m.doneCount, m.totalCount))
            .font(Typo.count)
            .foregroundStyle(Tok.textSecondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(format: String(localized: "projects.header.progress.a11y"), m.doneCount, m.totalCount))
    }

    private func canStartChips(_ m: ProjectInsights.HeaderMetrics) -> some View {
        HStack(spacing: Space.x1) {
            Text(String(localized: "projects.header.canstart"))
                .font(Typo.meta)
                .foregroundStyle(Tok.textTertiary)
            ForEach(m.canStart) { task in
                canStartChip(task)
            }
        }
    }

    private func canStartChip(_ task: KTask) -> some View {
        let gate = ProjectInsights.isGate(task, in: tasks)
        let label = gate ? "\(task.title) · \(String(localized: "flow.gate.title"))" : task.title
        return KChip(label, onTap: { model.selectedTaskID = task.id }) {
            if gate { Icon("flag", size: Metrics.iconXS).foregroundStyle(Tok.textSecondary) }
        }
        .uiTestAnchor("project.header.canstart.\(task.id.uuidString)")
    }

    private func stat(icon: String, value: Int, text: String) -> some View {
        HStack(spacing: Space.x1) {
            Icon(icon, size: Metrics.iconXS).foregroundStyle(Tok.textTertiary)
            Text("\(value)")
                .font(Typo.count)
                .foregroundStyle(Tok.textSecondary)
        }
        .help(text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    private func dueStat(_ day: Int) -> some View {
        let shown = ListDueText.shown(due: day, today: Day.today()).text
        let text = String(format: String(localized: "projects.header.due.a11y"), shown)
        return HStack(spacing: Space.x1) {
            Icon("calendar", size: Metrics.iconXS).foregroundStyle(Tok.textTertiary)
            Text(shown)
                .font(Typo.count)
                .foregroundStyle(Tok.textSecondary)
        }
        .help(text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}
