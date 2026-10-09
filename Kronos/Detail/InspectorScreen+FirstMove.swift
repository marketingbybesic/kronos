// Kronos/Detail/InspectorScreen+FirstMove.swift
// The "first move" field: split out of InspectorScreen.swift (UI-007) to keep that file inside
// the 500-line limit.
import SwiftUI
import KronosCore

extension InspectorScreen {
    // MARK: First move
    //
    // Root cause of a prior "cannot type into first move" bug: this section never carried a
    // TextField at all in an earlier revision — only a Text/placeholder pair — so there was no
    // control to type into. A second, related confusion: a task's first move and its subtasks
    // were two independent things on screen at once. `FirstMoveLogic.display` (Kronos/Detail/
    // FirstMoveLogic.swift) now makes them ONE: an open subtask exists -> read-only, sourced
    // from `task.nextOpenSubtask` (so reordering subtasks changes it for free, no copy to go
    // stale); otherwise the field really is `task.firstMove` and really saves.

    func firstMoveSection(_ task: KTask) -> some View {
        let display = FirstMoveLogic.display(for: task)
        return VStack(alignment: .leading, spacing: Space.x2) {
            InspectorSectionCaption(String(localized: "detail.firstmove"))
            KPanel {
                VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: Space.x2) {
                    Icon("zap", size: Metrics.iconM).foregroundStyle(Tok.textTertiary)
                    switch display {
                    case .fromSubtask(let title):
                        VStack(alignment: .leading, spacing: Space.x1) {
                            Text(title)
                                .font(Typo.body)
                                .foregroundStyle(Tok.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(String(localized: "detail.firstmove.fromsubtask.hint"))
                                .font(Typo.meta)
                                .foregroundStyle(Tok.textTertiary)
                        }
                    case .fromAttachment(let suggestion):
                        VStack(alignment: .leading, spacing: Space.x1) {
                            Text(suggestion.localized)
                                .font(Typo.body)
                                .foregroundStyle(Tok.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(String(localized: "detail.firstmove.fromattachment.hint"))
                                .font(Typo.meta)
                                .foregroundStyle(Tok.textTertiary)
                        }
                    case .editable(_, let hint):
                        TextField(hint?.localized ?? String(localized: "detail.firstmove.placeholder"), text: $drafts.firstMove, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(Typo.body)
                            .foregroundStyle(Tok.textPrimary)
                            .lineLimit(1...4)
                            .accessibilityLabel(String(localized: "detail.firstmove"))
                            .focused($focus, equals: .firstMove)
                            .onSubmit { commitFirstMove(task) }
                            .onChange(of: focus) { old, new in
                                if old == .firstMove, new != .firstMove { commitFirstMove(task) }
                            }
                            .kOnEscapeRevert(active: focus == .firstMove) {
                                drafts.revert(.firstMove, to: Self.shown(task))
                                focus = nil
                            }
                    }
                    Spacer(minLength: 0)
                }
                InspectorDreadToggle(model: model, task: task)
                    .padding(.top, Space.x2)
                }
            }
        }
    }

    /// Submit / blur of the first-move field: writes only what the user typed, never the copy
    /// loaded before the store (auto-triage, MCP) filled it.
    private func commitFirstMove(_ task: KTask) {
        guard drafts.taskID == task.id, drafts.isDirty(.firstMove) else { return }
        if let move = drafts.firstMoveToWrite(stored: Self.editableFirstMove(task), ownsFirstMove: task.nextOpenSubtask == nil) {
            model.store.setFirstMove(task.id, move.isEmpty ? nil : move)
            model.didMutate()
        }
        drafts.markCommitted(.firstMove, shown: Self.shown(model.store.task(task.id) ?? task))
    }
}
