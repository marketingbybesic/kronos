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
    @State private var drafts = InspectorDrafts()
    @FocusState private var focus: Field?

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
    private var task: KTask? { model.inspectedTask }

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

    // MARK: First move
    //
    // Root cause of a prior "cannot type into first move" bug: this section never carried a
    // TextField at all in an earlier revision — only a Text/placeholder pair — so there was no
    // control to type into. A second, related confusion: a task's first move and its subtasks
    // were two independent things on screen at once. `FirstMoveLogic.display` (Kronos/Detail/
    // FirstMoveLogic.swift) now makes them ONE: an open subtask exists -> read-only, sourced
    // from `task.nextOpenSubtask` (so reordering subtasks changes it for free, no copy to go
    // stale); otherwise the field really is `task.firstMove` and really saves.

    private func firstMoveSection(_ task: KTask) -> some View {
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

    // MARK: Notes

    private func notesSection(_ task: KTask) -> some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            HStack {
                InspectorSectionCaption(String(localized: "detail.notes"))
                Spacer()
                // The one "Link Apple note" button; hidden once a note is linked.
                if NoteLink.find(in: task.notes) == nil {
                    Button {
                        model.noteLinkPickerOpen = true
                    } label: {
                        HStack(spacing: Space.x2) {
                            Icon("note.text", size: Metrics.iconS)
                            Text(String(localized: "detail.notelink.add"))
                        }
                    }
                    .kButton(.secondary, size: .compact)
                    .uiTestAnchor("inspector.notes.notelink.add")
                }
            }
            InspectorNotesField(placeholder: String(localized: "detail.notes.placeholder"), text: $drafts.notes)
                .focused($focus, equals: .notes)
                .onChange(of: focus) { old, new in
                    if old == .notes, new != .notes { commitNotes(task) }
                }
                .onChange(of: drafts.notes) { _, _ in scheduleNotesAutosave(task) }
        }
    }

    @State private var notesAutosaveWork: DispatchWorkItem?

    private func scheduleNotesAutosave(_ task: KTask) {
        notesAutosaveWork?.cancel()
        let work = DispatchWorkItem { commitNotes(task) }
        notesAutosaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func commitNotes(_ task: KTask) {
        guard task.id == drafts.taskID, let draft = drafts.notesToMerge() else { return }
        let outcome = InspectorNotesSave.save(draft, to: task.id, editBase: notesEditBase, store: model.store)
        if outcome != nil { model.didMutate() }
        notesCommitted(task.id, outcome)
    }

    /// The full stored notes the notes draft started from (see InspectorNotesSave.swift).
    @State private var notesEditBase = ""

    /// After a notes save: the draft is in step with the store again. A save that kept another
    /// side's text shows the merged notes, so the next save starts from them and cannot drop them.
    private func notesCommitted(_ id: UUID, _ outcome: TextConflictMerge.Outcome?) {
        guard let now = model.store.task(id) else { return }
        if case .conflict? = outcome {
            drafts.revert(.notes, to: Self.shown(now))
        } else {
            drafts.markCommitted(.notes, shown: Self.shown(now))
        }
        notesEditBase = now.notes
    }

    // MARK: Draft lifecycle

    private func loadDrafts() {
        notesAutosaveWork?.cancel()
        guard let task else {
            drafts.load(taskID: nil, shown: InspectorDrafts.Shown())
            notesEditBase = ""
            return
        }
        drafts.load(taskID: task.id, shown: Self.shown(task))
        notesEditBase = task.notes
    }

    /// The store changed while this task is open: untouched fields follow it (a first move that
    /// auto-triage just filled appears), fields the user is typing in keep their text.
    private func reloadCleanDrafts() {
        guard let task, drafts.taskID == task.id else { return }
        drafts.reloadClean(shown: Self.shown(task))
        // Untouched notes follow the store, so a later edit starts from what is stored now.
        if !drafts.isDirty(.notes) { notesEditBase = task.notes }
    }

    /// Writes every dirty draft onto the task it was loaded from, now.
    private func flushDrafts() {
        guard let id = drafts.taskID else { return }
        commitDrafts(for: id)
    }

    private func commitDrafts(for id: UUID) {
        // The drafts belong to the task they were loaded from. Committing them onto another id (a
        // child's title must never land on its parent when the shown task changes)
        // must never happen: nothing is written unless the id is the loaded task. Only fields the
        // user actually typed in (dirty) are written; a clean draft is a stale copy by definition.
        notesAutosaveWork?.cancel()
        guard id == drafts.taskID, let t = model.store.task(id), !drafts.dirtyFields.isEmpty else { return }
        let title = drafts.titleToWrite(stored: t.title)
        let notesDraft = drafts.notesToMerge()
        let ownsFirstMove = t.nextOpenSubtask == nil   // only a task with no open subtask owns firstMove
        let firstMove = drafts.firstMoveToWrite(stored: Self.editableFirstMove(t), ownsFirstMove: ownsFirstMove)
        // Root cause of "first Cmd-Z does nothing" after Space/H: selection change runs this and
        // `store.update` ALWAYS pushes an undo step, burying the complete/snooze step under a no-op.
        // Title, first move and notes land as ONE undo step; notes go through the conflict-safe
        // save, which writes nothing when the visible text is what is stored.
        var notesOutcome: TextConflictMerge.Outcome?
        var wrote = false
        model.store.groupedUndo("Edit") {
            if title != nil || firstMove != nil {
                model.store.update(id) { task in
                    if let title { task.title = title }
                    if let firstMove { task.firstMove = firstMove.isEmpty ? nil : firstMove }
                }
                wrote = true
            }
            if let notesDraft {
                notesOutcome = InspectorNotesSave.save(notesDraft, to: id, editBase: notesEditBase, store: model.store)
                wrote = wrote || notesOutcome != nil
            }
        }
        if wrote { model.didMutate() }
        let now = Self.shown(model.store.task(id) ?? t)
        for field in drafts.dirtyFields {
            // An empty title cannot be written: it stays dirty (blur or Esc snaps it back).
            // A first move without ownership is not shown as editable: leave it untouched.
            if field == .title, drafts.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            if field == .firstMove, !ownsFirstMove { continue }
            if field == .notes { notesCommitted(id, notesOutcome); continue }
            drafts.markCommitted(field, shown: now)
        }
    }
}
