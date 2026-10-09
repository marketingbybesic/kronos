// InspectorScreen — the task inspector: every field labelled, first move never clipped,
// notes in a real hairline editor, calm empty state when nothing (or nothing live) is
// selected. Every edit goes through TaskStoring and calls model.didMutate(); nothing here
// touches SwiftData directly.
import SwiftUI
import AppKit
import KronosCore

struct InspectorScreen: View {
    let model: AppModel
    /// Snapshot-only override for `inspector.triaged` — see
    /// Kronos/Detail/InspectorCoachSection.swift's doc comment for why the live
    /// `AppDelegate.shared?.autoTriage` seam is unreachable from a harness process. Always
    /// nil on the real screen.
    var previewTriageFill: TriageFillDisplay?? = nil
    /// Snapshot-only: forces the "Vremenski blok" disclosure open. Always false on the real screen.
    var previewCalendarBlockExpanded: Bool = false
    /// Snapshot-only: Details open without touching UserDefaults. Always false on the real screen.
    var previewDetailsOpen: Bool = false
    /// Snapshot-only: the Project field opens its picker on appear with this text typed. Always nil on the real screen.
    var previewProjectPicker: String?
    /// Remembered across tasks and launches: a user who opens Details wants it open everywhere.
    @AppStorage("kronos.inspector.detailsOpen") private var detailsOpen = false
    /// Title, notes and first-move drafts with per-field dirty tracking (InspectorDrafts.swift).
    @State var drafts = InspectorDrafts()
    @FocusState var focus: Field?
    @State var notesAutosaveWork: DispatchWorkItem?
    /// The full stored notes the notes draft started from (see InspectorNotesSave.swift).
    @State var notesEditBase = ""

    enum Field: Hashable { case title, notes, subtaskAdd, firstMove }

    init(model: AppModel, previewTriageFill: TriageFillDisplay?? = nil, previewCalendarBlockExpanded: Bool = false,
         previewDetailsOpen: Bool = false, previewProjectPicker: String? = nil) {
        self.model = model
        self.previewProjectPicker = previewProjectPicker
        self.previewDetailsOpen = previewDetailsOpen
        self.previewTriageFill = previewTriageFill
        self.previewCalendarBlockExpanded = previewCalendarBlockExpanded
    }

    /// The task the inspector shows: the child being inspected (child mode) while it still
    /// belongs to the selected task, else the selected task itself. A child selected directly
    /// (a link, search) is shown the same way, with its parent in the breadcrumb.
    var task: KTask? { model.inspectedTask }

    var body: some View {
        // `task` is re-fetched from the store on every `body` call; reading `model.version` makes
        // `@Observable` re-run `body` after `model.didMutate()` (else a stale row until a redraw).
        let _ = model.version
        Group {
            if model.selectedIDs.count > 1 {
                BulkSelectionPanel(model: model)
            } else if let task {
                content(for: task)
                    .id(task.id)
            } else {
                InspectorEmptyState(model: model)
            }
        }
        .background(Tok.bg)
        .onChange(of: task?.id) { oldID, _ in
            // Selection moved, or child mode was entered/left: save the old task's drafts first.
            if let oldID { commitDrafts(for: oldID) }
            loadDrafts()
        }
        .onChange(of: model.selectedTaskID) { _, newID in
            if let sub = model.inspectedSubtaskID {
                let stillChild = newID.flatMap { model.store.task($0) }?.orderedChildren.contains { $0.id == sub } ?? false
                if !stillChild { model.inspectedSubtaskID = nil }
            }
        }
        .onChange(of: model.version) { _, _ in reloadCleanDrafts() }
        .onAppear { loadDrafts() }
        .onDisappear { flushDrafts() }
        // Quit and app deactivation write dirty drafts synchronously (the typed title survives a
        // ⌘Q or a switch to another app before the field ever loses focus).
        .onReceive(NotificationCenter.default.publisher(for: .kronosFlushDrafts)) { _ in flushDrafts() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in flushDrafts() }
        .onReceive(NotificationCenter.default.publisher(for: .kronosLinkNoteRequested)) { note in
            guard let taskID = note.userInfo?["taskID"] as? UUID else { return }
            model.selectedTaskID = taskID
            model.noteLinkPickerOpen = true
        }
        // Start on a task whose first move is only the generic placeholder: the cursor goes into
        // that task's notes. Return on a list row: the cursor goes into the title.
        .onReceive(NotificationCenter.default.publisher(for: .kronosFocusNotesRequested)) { note in
            focusRequested(.notes, note, select: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIRequests.focusInspectorTitle)) { note in
            focusRequested(.title, note, select: false)
        }
    }

    /// Puts the cursor in `field` of the task the request names (selecting it first when asked).
    /// The pane is rebuilt for a newly selected task, so the focus waits a beat.
    private func focusRequested(_ field: Field, _ note: Notification, select: Bool) {
        guard let taskID = note.userInfo?["taskID"] as? UUID else { return }
        if select { model.selectedTaskID = taskID }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            if model.inspectedTask?.id == taskID { focus = field }
        }
    }
    private func content(for task: KTask) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.inspectorSectionGap) {
                if let parent = task.parent { breadcrumb(parent) }
                header(task)
                // The person's check of an agent's "done" report needs a decision: it sits above Details, always visible.
                InspectorReviewSection(model: model, task: task)
                firstMoveSection(task)
                    .tourAnchor(.inspectorFirstMove)
                InspectorAttributesRow(model: model, task: task)
                InspectorProjectField(model: model, task: task, previewQuery: previewProjectPicker)
                VStack(alignment: .leading, spacing: 0) {
                    // Unlinked: the Notes header owns "Link Apple note"; this row only hosts its picker.
                    if NoteLink.find(in: task.notes) != nil {
                        InspectorNoteLinkRow(model: model, task: task, requestOpen: .constant(false))
                    }
                }
                LinksSection(model: model, target: .task(task.id))
                // One level only: a child has no steps of its own and no breakdown into steps.
                if !task.isSubtask {
                    InspectorStepsSection(model: model, task: task)
                        .uiTestAnchor("inspector.steps")
                }
                notesSection(task)
                if let rationale = task.triageRationale, !rationale.isEmpty {
                    InspectorRationalePanel(rationale: rationale)
                }
                detailsSection(task)
                InspectorFooter(model: model, task: task)
            }
            // Without an explicit width, a wide child (a Menu's .fixedSize() label, an
            // unwrapped long title) inflates the ScrollView's whole horizontal content
            // and the narrow window then shows a horizontally-shifted middle slice
            // instead of wrapped text — caught on the 300pt screenshot read.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.x4)
        }
        .kContextLinkDrop(taskID: task.id, model: model)
        .focusable()
        .focusEffectDisabled()
        .kPasteURLAsLink(model: model, target: .task(task.id))
        .scrollDismissesKeyboard(.interactively)
        .onKeyPress(.escape) {
            commitDrafts(for: task.id)
            focus = nil
            if task.isSubtask {
                // Child mode: Esc goes back to the parent.
                model.closeChildDetails()
                return .handled
            }
            NotificationCenter.default.post(name: Notification.Name("kronosFocusListRequested"), object: nil)
            return .handled
        }
        .onKeyPress(.return, phases: .down) { press in
            guard press.modifiers.contains(.command), focus != .notes else { return .ignored }
            toggleDone(task)
            return .handled
        }
    }

    // MARK: Breadcrumb (child mode)

    /// "‹ Parent title" above a child's header; one click returns to the parent task.
    private func breadcrumb(_ parent: KTask) -> some View {
        Button {
            commitDrafts(for: task?.id ?? parent.id)
            model.closeChildDetails()
        } label: {
            HStack(spacing: Space.x1) {
                Icon("chevron-left", size: Metrics.iconS)
                Text(parent.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(Typo.meta)
            .foregroundStyle(Tok.textTertiary)
            .frame(maxWidth: .infinity, minHeight: Metrics.minHit, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "detail.subtask.back"))
        .kTooltip(String(localized: "detail.help.back"))
        .uiTestAnchor("inspector.child.back")
    }

    // MARK: Header — completion + title + focus pin

    private func header(_ task: KTask) -> some View {
        VStack(alignment: .leading, spacing: Space.x1) {
            HStack(alignment: .top, spacing: Space.x2) {
                KCheckbox(isChecked: task.status == .done) { toggleDone(task) }
                    .padding(.top, Space.x1)
                TextField(String(localized: "detail.title.placeholder"), text: $drafts.title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Typo.display)
                    .tracking(Tracking.tight)
                    .foregroundStyle(Tok.textPrimary)
                    .lineLimit(1...3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(String(localized: "detail.title.placeholder"))
                    .focused($focus, equals: .title)
                    .onSubmit { commitTitle(task) }
                    .onChange(of: focus) { old, new in
                        if old == .title, new != .title { commitTitle(task) }
                    }
                    // Esc keeps what was typed (an empty title still snaps back) and hands the
                    // keys back to the list, like Esc anywhere else in the inspector.
                    .kOnEscapeRevert(active: focus == .title) {
                        commitTitle(task)
                        focus = nil
                        NotificationCenter.default.post(name: UIRequests.focusList, object: nil)
                    }
                    .uiTestAnchor("inspector.title")
            }
            // KCheckbox's own layout width is Metrics.minHit (its hit-box), not its visual
            // circle size, so the lines below indent by that plus the gap.
            InspectorSourceLine(task: task)
                .padding(.leading, Metrics.minHit + Space.x2)
            InspectorTriageFillRow(model: model, task: task, previewFill: previewTriageFill)
                .padding(.leading, Metrics.minHit + Space.x2)
        }
    }

    // MARK: Details — everything that is not the task itself, behind one disclosure

    /// One click reaches every other field (status, labels, depth, estimate, repeat, time
    /// block, focus, re-triage); the default view stays title, first move, the three
    /// first-class attributes, the project, links, subtasks and notes. One borderless property list
    /// (style G): a hairline only where the fields genuinely group.
    private func detailsSection(_ task: KTask) -> some View {
        InspectorDetailsDisclosure(isOpen: previewDetailsOpen ? .constant(true) : $detailsOpen) {
            VStack(alignment: .leading, spacing: 0) {
                // One property list: every row carries its own hairline, none above the first.
                KPropertyList {
                    InspectorStatusSection(model: model, task: task)
                    InspectorDepthEstimateSection(model: model, task: task)
                    InspectorRecurrenceSection(model: model, task: task)
                }
                KHairline()
                InspectorCalendarBlockRow(model: model, task: task, forceExpandedOnAppear: previewCalendarBlockExpanded)
                HStack(spacing: Space.x3) {
                    focusPinControl(task)
                    InspectorRetriageControl(model: model, task: task)
                    markReviewedControl(task)
                    delegateControl(task)
                }
            }
        }
    }

    /// Quiet text control, not a button face: pins/unpins this task as the Now card's
    /// focus (`model.pinnedFocusTaskID`) independent of Ordo's automatic pick. Reads
    /// "Focus this" when this task isn't the pin, "Unpin focus" when it is — never both
    /// at once, so there is exactly one action per state (no toggle-labelled-as-noun).
    private func focusPinControl(_ task: KTask) -> some View {
        let isPinned = model.pinnedFocusTaskID == task.id
        // Root cause of a "must click 2-3 times" bug found in live UI testing: a `.frame`
        // chained after `.buttonStyle(.plain)` with no `.contentShape` only leaves the label's
        // own opaque pixels (icon+text) pressable — the frame's extra height was dead space.
        // Frame + contentShape now live inside the label closure.
        return Button {
            model.pinnedFocusTaskID = isPinned ? nil : task.id
        } label: {
            HStack(spacing: Space.x1) {
                Icon("target", size: Metrics.iconXS)
                Text(String(localized: isPinned ? "detail.focus.unpin" : "detail.focus.pin"))
            }
            .font(Typo.meta)
            .foregroundStyle(isPinned ? Tok.textSecondary : Tok.textTertiary)
            .frame(height: Metrics.minHit, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .kTooltip(String(localized: isPinned ? "detail.help.unpin" : "detail.help.focus"))
    }

    /// Quiet text control, same family as `focusPinControl`: the person's "reviewed"
    /// phase-gate mark (finish-round-1 B3). Any agent can read it with the read-only
    /// `review_status` MCP tool; no tool can set it, only this control and its context-menu
    /// equivalent (TaskMenu.nodes). Backed by the device-local activity log (ReviewedMarkHub),
    /// NOT a KTask field — a schema change there would break every already-persisted V2 store's
    /// entity-hash match (see SchemaV1Frozen.swift's header). Not part of TaskStore's undo
    /// stack for the same reason `setReviewed` documents; the toast says so (showNotice, not
    /// the undo-pill `model.commit`).
    private func markReviewedControl(_ task: KTask) -> some View {
        let isReviewed = ReviewedMarkHub.shared?.isReviewed(task.id) ?? false
        return Button {
            ReviewedMarkHub.shared?.setReviewed(!isReviewed, taskID: task.id, agentID: task.agentID)
            model.didMutate()
            UndoToastCenter.shared.showNotice(String(format: String(localized: isReviewed ? "undo.unreviewed.name" : "undo.reviewed.name"), task.title))
        } label: {
            HStack(spacing: Space.x1) {
                Icon(isReviewed ? "check-circle" : "circle", size: Metrics.iconXS)
                Text(String(localized: isReviewed ? "detail.reviewed.unmark" : "detail.reviewed.mark"))
            }
            .font(Typo.meta)
            .foregroundStyle(isReviewed ? Tok.textSecondary : Tok.textTertiary)
            .frame(height: Metrics.minHit, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .kTooltip(String(localized: isReviewed ? "detail.help.reviewed.unmark" : "detail.help.reviewed.mark"))
        .uiTestAnchor("inspector.reviewed.toggle")
    }

    /// Quiet text control, same family as `focusPinControl`/`markReviewedControl`: hands this
    /// task to a configured agent, or takes it back. Reads/writes `KTask.agentID` +
    /// `assigneeRaw` directly (the same pair `complete_task` already reads — no new field),
    /// the same write TaskMenu.nodes's "Delegate to…" submenu uses
    /// (Kronos/List/TaskContextMenu.swift's `TaskDelegation`), so the two can't drift.
    /// Disabled, with a tooltip explaining why, only when there is no agent to offer AND this
    /// task is not already delegated — never a control that silently does nothing.
    private func delegateControl(_ task: KTask) -> some View {
        let all = ReviewedMarkHub.shared?.agents() ?? []
        let pickable = all.filter(\.isEnabled)
        let current = task.assigneeRaw == 1 ? all.first { $0.id == task.agentID } : nil
        let isInert = pickable.isEmpty && current == nil
        return Menu {
            ForEach(pickable, id: \.id) { (agent: KAgent) in
                Button(agent.displayName) { TaskDelegation.delegate(task.id, to: agent, model: model) }
            }
            if current != nil {
                if !pickable.isEmpty { Divider() }
                Button(String(localized: "ctx.task.delegate.remove")) { TaskDelegation.undelegate(task.id, model: model) }
            }
        } label: {
            HStack(spacing: Space.x1) {
                Icon("arrowshape.turn.up.right", size: Metrics.iconXS)
                Text(current.map { String(format: String(localized: "detail.delegate.current"), $0.displayName) }
                     ?? String(localized: "ctx.task.delegate"))
            }
            .font(Typo.meta)
            .foregroundStyle(current != nil ? Tok.textSecondary : Tok.textTertiary)
            .frame(height: Metrics.minHit, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .disabled(isInert)
        .opacity(isInert ? 0.4 : 1)
        .kTooltip(isInert ? String(localized: "detail.help.delegate.none") : String(localized: "detail.help.delegate"))
        .uiTestAnchor("inspector.delegate")
    }

    private func toggleDone(_ task: KTask) {
        // Same helper the list row uses (Kronos/List/ListCompletion.swift) so completing from
        // the inspector raises the same shell-level undo pill everywhere.
        ListCompletion.toggle(task, store: model.store, model: model)
    }

    /// Submit / blur of the title field. Nothing is written unless the user typed in it; an empty
    /// or unchanged title snaps back to the stored one.
    private func commitTitle(_ task: KTask) {
        guard drafts.taskID == task.id, drafts.isDirty(.title) else { return }
        if let title = drafts.titleToWrite(stored: task.title) {
            model.store.update(task.id) { $0.title = title }
            model.didMutate()
            drafts.markCommitted(.title, shown: Self.shown(model.store.task(task.id) ?? task))
        } else {
            drafts.revert(.title, to: Self.shown(task))
        }
    }

}

/// One `AgentHub` over the device-local store, opened once and reused by the "reviewed" mark
/// controls (InspectorScreen's `markReviewedControl`, TaskContextMenu's node): re-opening a
/// SwiftData container on every render/click would be wasteful. `nil` only if the device-local
/// store cannot be opened at all (same failure mode `AgentsSettingsController` already tolerates
/// with the identical `try? AgentHub(directory:)` call) — the mark control still renders, it
/// just always reads "not reviewed" and silently no-ops on toggle.
@MainActor
enum ReviewedMarkHub {
    static let shared: AgentHub? = try? AgentHub(directory: KronosStore.containerDirectory())
}
