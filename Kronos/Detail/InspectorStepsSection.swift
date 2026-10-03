// STEPS (subtasks): checkbox list, inline add (Return adds and keeps focus), toggle,
// inline rename (double-click or Return enters edit mode), delete, progress caption,
// reorder. Rename/reorder/delete each go through their own TaskStoring setter (rev 4),
// so every step edit is its own named undo step rather than a raw `update` rewriting
// the whole subtasks array.
// Reorder is by dragging a row (an insertion line shows where it lands: accent, 2 pt, dot at the
// left, the same indicator as the list) or by Option-Up/Down on a focused row; there are no
// arrow buttons. A file/folder/Mail message dropped on a row attaches to THAT subtask (small
// chips right of the title). One drop delegate tells the two apart synchronously: a row drag
// carries `kronos-subtask:<uuid>` as its text, read straight off the drag pasteboard — no async
// NSItemProvider round-trip, no state that a cancelled drag could leave behind. Each row has
// an ⓘ button that opens the inspector in subtask mode.
import SwiftUI
import AppKit
import KronosCore

struct InspectorStepsSection: View {
    let model: AppModel
    let task: KTask
    @State private var renamingStepID: UUID?
    @State private var renameDraft = ""
    @FocusState private var renameFieldFocused: Bool
    /// Keyboard path for reorder/delete/rename: which step row currently has keyboard
    /// focus, independent of hover (hover still drives the trailing button trio).
    @FocusState private var focusedStepID: UUID?

    /// The row a file/mail drag is currently over (attachment), for the dashed outline.
    @State private var dropTargetStepID: UUID?
    /// Where a dragged step would land (slot 0...count), for the insertion line; nil when no
    /// reorder is under way or the drop would change nothing.
    @State private var insertionSlot: Int?

    /// Snapshot-only: forces one step straight into rename mode on appear, without
    /// touching the store while the screens dictionary is being built.
    var forceRenameOnAppear: Bool = false
    /// Snapshot-only: opens the Break down preview on appear with a fixed result,
    /// bypassing `model.ai` entirely so the harness never awaits a real call.
    var forceBreakdownPreview: BreakdownResult?
    /// Snapshot-only: draws the reorder insertion line at this slot on appear.
    var previewInsertionSlot: Int?

    @State private var isBreakdownOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            HStack {
                InspectorSectionCaption(String(localized: "detail.subtasks"))
                Spacer()
                if progress.total > 0 {
                    Text(String(format: String(localized: "list.subtask.progress.n_of_m"), progress.done, progress.total))
                        .font(Typo.meta)
                        .foregroundStyle(Tok.textTertiary)
                }
                Button { isBreakdownOpen = true } label: { Text(String(localized: "detail.breakdown")).kHitTarget(alignment: .trailing) }
                    .buttonStyle(.plain)
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                    .disabled(isBreakdownOpen)
                    .kTooltip(String(localized: "detail.help.breakdown"))
                    .uiTestAnchor("inspector.breakdown.open")
            }
            VStack(spacing: Space.x1) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                    stepRow(step, index: index)
                        .onDrag { NSItemProvider(object: (MailDropPasteboard.subtaskDragPrefix + step.id.uuidString) as NSString) }
                        .onDrop(of: ContextLinkDropModifier.acceptedTypes,
                                delegate: SubtaskRowDropDelegate(step: step, rowIndex: index, steps: steps, model: model,
                                                                 hoveredID: $dropTargetStepID, insertionSlot: $insertionSlot))
                }
                addRow
                    .overlay(alignment: .top) { if insertionSlot == steps.count { StepInsertionLine() } }
                    .onDrop(of: ContextLinkDropModifier.acceptedTypes,
                            delegate: SubtaskRowDropDelegate(step: nil, rowIndex: steps.count, steps: steps, model: model,
                                                             hoveredID: $dropTargetStepID, insertionSlot: $insertionSlot))
            }
            if isBreakdownOpen {
                InspectorBreakdownPreview(model: model, task: task,
                                          existingSubtaskTitles: steps.map(\.title),
                                          onClose: { isBreakdownOpen = false },
                                          previewResult: forceBreakdownPreview)
                    .uiTestAnchor("inspector.breakdown.preview")
                    .transition(Motion.reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(Motion.curve(Motion.fast), value: isBreakdownOpen)
        .onChange(of: BreakdownRequests.shared.pendingTaskID) { _, _ in takeBreakdownRequest() }
        .onAppear {
            takeBreakdownRequest()
            if forceRenameOnAppear, let first = steps.first {
                beginRename(first)
            }
            if forceBreakdownPreview != nil {
                isBreakdownOpen = true
            }
            if let previewInsertionSlot { insertionSlot = previewInsertionSlot }
        }
    }

    /// A "Break down" asked for from outside (menu, palette, B key) opens the preview at once.
    private func takeBreakdownRequest() {
        if BreakdownRequests.shared.take(for: task.id) { isBreakdownOpen = true }
    }

    private var steps: [KTask] { task.orderedSubtasks }
    private var progress: (done: Int, total: Int) { task.subtaskProgress }

    @State private var hoveredStepID: UUID?

    /// One compact line, matching the design system's list-row height: checkbox, title,
    /// due/priority marks when set, the ⓘ button into the step's own inspector and — only on
    /// hover, so an at-rest step reads as plainly as a checklist — a delete ✕. Reordering is by
    /// dragging the row (insertion line); there are no arrow buttons.
    ///
    /// Keyboard path, for a step that has keyboard focus: Option-Up/Down reorders, Delete
    /// removes (goes through the same TaskStoring call as the hover ✕, so it's the same 5s
    /// undo), Return enters rename. The row is
    /// `.focusable` with `.focusEffectDisabled()` — a plain focus ring on a list row is
    /// a documented trap here (ui-common.md), so focus reads through the same quiet
    /// fill hover already uses rather than a ring nobody asked for.
    private func stepRow(_ step: KTask, index: Int) -> some View {
        HStack(spacing: Space.x2) {
            KCheckbox(isChecked: step.isDone, size: Metrics.iconL, label: step.title) {
                model.store.toggleSubtask(step.id)
                model.didMutate()
            }
            if renamingStepID == step.id {
                TextField(String(localized: "detail.subtasks.add"), text: $renameDraft)
                    .textFieldStyle(.plain)
                    .font(Typo.row)
                    .foregroundStyle(Tok.textPrimary)
                    .focused($renameFieldFocused)
                    .onSubmit { commitRename(step) }
                    .kOnEscapeRevert(active: renameFieldFocused) { cancelRename() }
                    .onChange(of: renameFieldFocused) { old, new in
                        if old, !new { commitRename(step) }
                    }
            } else {
                Text(step.title)
                    .font(Typo.row)
                    .foregroundStyle(step.isDone ? Tok.textTertiary : Tok.textPrimary)
                    .strikethrough(step.isDone)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                    .onTapGesture(count: 2) { beginRename(step) }
            }
            SubtaskAttachmentChips(model: model, subtask: step)
            Spacer(minLength: Space.x2)
            SubtaskMetaBadges(subtask: step)
            if hoveredStepID == step.id || focusedStepID == step.id {
                Button { deleteStep(step) } label: {
                    Icon("x", size: Metrics.iconXS)
                        .foregroundStyle(Tok.textTertiary)
                        .frame(width: Metrics.minHit, height: Metrics.minHit)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "common.delete"))
            }
            // Always visible: the way into the step's own inspector (due, priority, notes, links).
            Button { model.openDetails(taskID: step.id) } label: {
                Icon("info", size: Metrics.iconS)
                    .foregroundStyle(hoveredStepID == step.id ? Tok.textSecondary : Tok.textTertiary)
                    .frame(width: Metrics.minHit, height: Metrics.minHit)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "detail.subtask.open"))
            .kTooltip(String(localized: "detail.help.openstep"))
            .uiTestAnchor("inspector.step.info.\(index)")
        }
        .frame(height: Metrics.rowHeight)
        .padding(.horizontal, Space.x1)
        .background(
            RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                .fill(focusedStepID == step.id && renamingStepID != step.id ? Tok.hoverFill : Color.clear)
        )
        .overlay {
            if dropTargetStepID == step.id {
                RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                    .strokeBorder(Tok.borderActive, style: StrokeStyle(lineWidth: Metrics.strokeQuiet, dash: [Space.x1, Space.x1]))
            }
        }
        .overlay(alignment: .top) { if insertionSlot == index { StepInsertionLine() } }
        .uiTestAnchor("inspector.step.row.\(index)")
        .contentShape(Rectangle())
        .kSubtaskContextMenu(step, parent: task, model: model, place: "step")
        .onHover { hoveredStepID = $0 ? step.id : nil }
        .focusable(renamingStepID != step.id)
        .focusEffectDisabled()
        .focused($focusedStepID, equals: step.id)
        .onChange(of: focusedStepID) { old, new in SubtaskFocus.note(old: old, new: new) }
        // A click on the row (not only Tab) puts keyboard focus on it, so Cmd-[ and Option-arrows act on it.
        .simultaneousGesture(TapGesture().onEnded { if renamingStepID != step.id { focusedStepID = step.id } })
        .uiTestAnchor("step." + step.title)
        .onKeyPress(.upArrow, phases: .down) { press in
            guard focusedStepID == step.id, press.modifiers.contains(.option) else { return .ignored }
            move(step, by: -1)
            return .handled
        }
        .onKeyPress(.downArrow, phases: .down) { press in
            guard focusedStepID == step.id, press.modifiers.contains(.option) else { return .ignored }
            move(step, by: 1)
            return .handled
        }
        .onKeyPress(.deleteForward) { deleteIfFocused(step) }
        .onKeyPress(.delete) { deleteIfFocused(step) }
        .onKeyPress(.return) {
            guard focusedStepID == step.id else { return .ignored }
            beginRename(step)
            return .handled
        }
        .animation(Motion.hover, value: focusedStepID)
    }

    private func deleteIfFocused(_ step: KTask) -> KeyPress.Result {
        guard focusedStepID == step.id else { return .ignored }
        deleteStep(step)
        return .handled
    }

    private func deleteStep(_ step: KTask) {
        model.store.deleteSubtask(step.id)
        model.didMutate()
    }

    private var addRow: some View {
        SubtaskEntryRow(model: model, parentID: task.id, place: "inspector")
    }

    private func beginRename(_ step: KTask) {
        renameDraft = step.title
        renamingStepID = step.id
        renameFieldFocused = true
    }

    private func commitRename(_ step: KTask) {
        guard renamingStepID == step.id else { return }
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != step.title {
            model.store.renameSubtask(step.id, title: trimmed)
            model.didMutate()
        }
        renamingStepID = nil
    }

    private func cancelRename() {
        renamingStepID = nil
    }

    private func move(_ step: KTask, by offset: Int) {
        let ordered = steps
        guard let from = ordered.firstIndex(where: { $0.id == step.id }) else { return }
        let to = from + offset
        guard ordered.indices.contains(to) else { return }
        // reorderSubtask places `step` directly BEFORE `before`; moving down one slot
        // means "before the element currently two past it" (or to the end).
        let before: UUID? = offset < 0 ? ordered[to].id : (ordered.indices.contains(to + 1) ? ordered[to + 1].id : nil)
        model.store.reorderSubtask(step.id, before: before)
        model.didMutate()
    }
}

/// The reorder indicator: the same mark the list draws between rows (accent, 2 pt, a dot at the
/// left), straddling the top edge of the row it sits above.
struct StepInsertionLine: View {
    @Environment(\.kAccent) private var accent
    private let dot: CGFloat = 8

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(accent).frame(height: 2)
            Circle().fill(accent).frame(width: dot, height: dot).offset(x: -dot / 2)
        }
        .frame(maxWidth: .infinity)
        .offset(y: -Space.x1 / 2 - 1)
        .allowsHitTesting(false)
        .uiTestAnchor("inspector.step.insertion")
    }
}

/// One drop target per subtask row (and one for the add row below the last, `step == nil`).
/// Kronos's own row drag (text `kronos-subtask:<uuid>` on the drag pasteboard) reorders: the
/// pointer's half of the row picks the slot above or below it, the insertion line shows it
/// while hovering, and the drop moves the step there in ONE store call — or does nothing when
/// the slot leaves the order unchanged. Anything else — Finder files/folders, Mail messages,
/// links — attaches to this subtask through the same routine the task-level drop uses.
struct SubtaskRowDropDelegate: DropDelegate {
    let step: KTask?
    let rowIndex: Int
    let steps: [KTask]
    let model: AppModel
    @Binding var hoveredID: UUID?
    @Binding var insertionSlot: Int?

    private var draggedID: UUID? { MailDropPasteboard.subtaskID(from: NSPasteboard(name: .drag)) }

    private func slot(for info: DropInfo) -> Int {
        step == nil ? steps.count : StepReorder.slot(rowIndex: rowIndex, y: Double(info.location.y), rowHeight: Double(Metrics.rowHeight))
    }

    /// The slot to show/commit, nil when this is not an internal drag or it would change nothing.
    private func effectiveSlot(for info: DropInfo) -> Int? {
        guard let draggedID else { return nil }
        let slot = slot(for: info)
        return StepReorder.move(order: steps.map(\.id), dragged: draggedID, slot: slot) == nil ? nil : slot
    }

    func dropEntered(info: DropInfo) { update(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: draggedID != nil ? .move : .copy)
    }

    func dropExited(info: DropInfo) {
        if let step, hoveredID == step.id { hoveredID = nil }
        insertionSlot = nil
    }

    private func update(_ info: DropInfo) {
        if draggedID != nil {
            hoveredID = nil
            let next = effectiveSlot(for: info)
            if insertionSlot != next { insertionSlot = next }
        } else {
            insertionSlot = nil
            hoveredID = step?.id
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        hoveredID = nil
        let committed = effectiveSlot(for: info)
        insertionSlot = nil
        guard let draggedID else {
            guard let step else { return false }
            return ContextLinkDropModifier.accept(info.itemProviders(for: ContextLinkDropModifier.acceptedTypes),
                                                  target: .subtask(step), model: model)
        }
        guard let committed, let before = StepReorder.move(order: steps.map(\.id), dragged: draggedID, slot: committed) else { return false }
        model.store.reorderSubtask(draggedID, before: before)
        model.didMutate()
        return true
    }
}
