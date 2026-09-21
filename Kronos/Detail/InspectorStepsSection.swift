// STEPS (subtasks): checkbox list, inline add (Return adds and keeps focus), toggle,
// inline rename (double-click or Return enters edit mode), delete, progress caption,
// reorder. Rename/reorder/delete each go through their own TaskStoring setter (rev 4),
// so every step edit is its own named undo step rather than a raw `update` rewriting
// the whole subtasks array. Reorder still uses move-up/move-down buttons rather than a
// drag gesture: SwiftUI's onDrag/onDrop needs an async NSItemProvider round-trip to
// identify the dragged row, which a plain String payload can't do synchronously —
// shipping that half-built would look like reordering but silently do nothing, which is
// worse than a keyboard-safe button pair.
import SwiftUI
import KronosCore

struct InspectorStepsSection: View {
    let model: AppModel
    let task: KTask
    @State private var newStepTitle = ""
    @FocusState private var addFieldFocused: Bool
    @State private var renamingStepID: UUID?
    @State private var renameDraft = ""
    @FocusState private var renameFieldFocused: Bool
    /// Keyboard path for reorder/delete/rename: which step row currently has keyboard
    /// focus, independent of hover (hover still drives the trailing button trio).
    @FocusState private var focusedStepID: UUID?

    /// Snapshot-only: forces one step straight into rename mode on appear, without
    /// touching the store while the screens dictionary is being built.
    var forceRenameOnAppear: Bool = false
    /// Snapshot-only: opens the Break down preview on appear with a fixed result,
    /// bypassing `model.ai` entirely so the harness never awaits a real call.
    var forceBreakdownPreview: BreakdownResult?

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
                Button(String(localized: "detail.breakdown")) { isBreakdownOpen = true }
                    .buttonStyle(.plain)
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                    .disabled(isBreakdownOpen)
            }
            VStack(spacing: Space.x1) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                    stepRow(step, index: index)
                }
                addRow
            }
            if isBreakdownOpen {
                InspectorBreakdownPreview(model: model, task: task,
                                          existingSubtaskTitles: steps.map(\.title),
                                          onClose: { isBreakdownOpen = false },
                                          previewResult: forceBreakdownPreview)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(Motion.curve(Motion.fast), value: isBreakdownOpen)
        .onAppear {
            if forceRenameOnAppear, let first = steps.first {
                beginRename(first)
            }
            if forceBreakdownPreview != nil {
                isBreakdownOpen = true
            }
        }
    }

    private var steps: [KSubtask] { task.orderedSubtasks }
    private var progress: (done: Int, total: Int) { task.subtaskProgress }

    @State private var hoveredStepID: UUID?

    /// One compact line, matching the design system's list-row height: checkbox, title,
    /// and — only on hover, so an at-rest step reads as plainly as a checklist — the
    /// move-up/move-down/delete trio side by side at the trailing edge (caught in
    /// review: two stacked chevrons per row doubled every step's height and rendered
    /// the fallback glyph because "chevron-up" isn't in Icon.swift's map; the map only
    /// has "arrow-up"/"arrow-down", which is also the clearer verb for reordering).
    ///
    /// Keyboard path alongside the hover buttons, for a step that has keyboard focus:
    /// Option-Up/Down reorders, Delete removes (goes through the same TaskStoring call
    /// as the hover ✕, so it's the same 5s undo), Return enters rename. The row is
    /// `.focusable` with `.focusEffectDisabled()` — a plain focus ring on a list row is
    /// a documented trap here (ui-common.md), so focus reads through the same quiet
    /// fill hover already uses rather than a ring nobody asked for.
    private func stepRow(_ step: KSubtask, index: Int) -> some View {
        HStack(spacing: Space.x2) {
            KCheckbox(isChecked: step.isDone, size: Metrics.iconL) {
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
                    .onTapGesture(count: 2) { beginRename(step) }
            }
            Spacer(minLength: Space.x2)
            if hoveredStepID == step.id || focusedStepID == step.id {
                HStack(spacing: 0) {
                    Button { move(step, by: -1) } label: { Icon("arrow-up", size: Metrics.iconXS) }
                        .kButton(.icon, size: .compact)
                        .disabled(index == 0)
                        .accessibilityLabel(String(localized: "detail.step.moveup"))
                    Button { move(step, by: 1) } label: { Icon("arrow-down", size: Metrics.iconXS) }
                        .kButton(.icon, size: .compact)
                        .disabled(index == steps.count - 1)
                        .accessibilityLabel(String(localized: "detail.step.movedown"))
                    Button {
                        deleteStep(step)
                    } label: {
                        Icon("x", size: Metrics.iconXS)
                    }
                    .kButton(.icon, size: .compact)
                    .accessibilityLabel(String(localized: "common.delete"))
                }
            }
        }
        .frame(height: Metrics.rowHeight)
        .padding(.horizontal, Space.x1)
        .background(
            RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                .fill(focusedStepID == step.id && renamingStepID != step.id ? Tok.hoverFill : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hoveredStepID = $0 ? step.id : nil }
        .focusable(renamingStepID != step.id)
        .focusEffectDisabled()
        .focused($focusedStepID, equals: step.id)
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

    private func deleteIfFocused(_ step: KSubtask) -> KeyPress.Result {
        guard focusedStepID == step.id else { return .ignored }
        deleteStep(step)
        return .handled
    }

    private func deleteStep(_ step: KSubtask) {
        model.store.deleteSubtask(step.id)
        model.didMutate()
    }

    private var addRow: some View {
        HStack(spacing: Space.x2) {
            Icon("plus", size: Metrics.iconS).foregroundStyle(Tok.textTertiary)
            TextField(String(localized: "detail.subtasks.add"), text: $newStepTitle)
                .textFieldStyle(.plain)
                .font(Typo.row)
                .foregroundStyle(Tok.textPrimary)
                .focused($addFieldFocused)
                .onSubmit(addStep)
        }
        .frame(height: Metrics.controlRegular)
    }

    private func addStep() {
        let trimmed = newStepTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.store.addSubtask(task.id, title: trimmed)
        model.didMutate()
        newStepTitle = ""
        addFieldFocused = true   // Return adds and keeps focus for the next step
    }

    private func beginRename(_ step: KSubtask) {
        renameDraft = step.title
        renamingStepID = step.id
        renameFieldFocused = true
    }

    private func commitRename(_ step: KSubtask) {
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

    private func move(_ step: KSubtask, by offset: Int) {
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
