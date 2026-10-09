// What the inspector shows when no task is selected: the task Kronos would have you start (the
// pinned focus, else the automatic pick) with its first move and one "Open" button, so an empty
// pane is a next step, not a blank. With no open focus task it falls back to the calm empty state.
import SwiftUI
import KronosCore

struct InspectorEmptyState: View {
    let model: AppModel
    /// Snapshot-only: renders the fallback although the seed has a focus task. Always false live.
    var previewNoFocus = false

    /// The focus task while it is still open; a done, deleted or missing one is not offered.
    private var focusTask: KTask? {
        guard !previewNoFocus, let id = model.focusTaskID, let task = model.store.task(id), KStatus.open.contains(task.status) else { return nil }
        return task
    }

    var body: some View {
        let _ = model.version
        if let task = focusTask {
            focusCard(task)
        } else {
            KEmptyState(icon: "check-square",
                        title: String(localized: "detail.empty.title"),
                        message: String(localized: "detail.empty.body"),
                        action: KEmptyState.Action(title: String(localized: "list.new")) {
                            NotificationCenter.default.post(name: .kronosNewTaskRequested, object: nil)
                        })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func focusCard(_ task: KTask) -> some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            InspectorSectionCaption(String(localized: "detail.empty.focus"))
            KPanel {
                VStack(alignment: .leading, spacing: Space.x2) {
                    Text(task.title)
                        .font(Typo.rowStrong)
                        .foregroundStyle(Tok.textPrimary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    if let move = FirstMoveLogic.text(for: task) {
                        HStack(alignment: .top, spacing: Space.x2) {
                            Icon("zap", size: Metrics.iconM)
                                .foregroundStyle(Tok.textTertiary)
                                .accessibilityHidden(true)
                            Text(move)
                                .font(Typo.body)
                                .foregroundStyle(Tok.textSecondary)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            .uiTestAnchor("inspector.empty.focus")
            Button(String(localized: "detail.empty.focus.open")) {
                model.selectedTaskID = task.id
            }
            .kButton(.secondary)
            .uiTestAnchor("inspector.empty.focus.open")
            Text(String(localized: "detail.empty.body"))
                .font(Typo.meta)
                .foregroundStyle(Tok.textTertiary)
        }
        .padding(Space.x4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
