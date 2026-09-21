// InspectorScreen — the task inspector: every field labelled, first move never clipped,
// notes in a real hairline editor, calm empty state when nothing (or nothing live) is
// selected. Every edit goes through TaskStoring and calls model.didMutate(); nothing here
// touches SwiftData directly.
import SwiftUI
import KronosCore

struct InspectorScreen: View {
    let model: AppModel
    /// Snapshot-only override for `inspector.triaged` — see
    /// Kronos/Detail/InspectorCoachSection.swift's doc comment for why the live
    /// `AppDelegate.shared?.autoTriage` seam is unreachable from a harness process. Always
    /// nil on the real screen.
    var previewTriageFill: TriageFillDisplay?? = nil
    /// Snapshot-only: forces the "Vremenski blok" disclosure open for `inspector.block.open`
    /// (`InspectorCalendarBlockRow`'s own doc comment explains why a harness can't seed fake
    /// unlinked blocks). Always false on the real screen.
    var previewCalendarBlockExpanded: Bool = false
    @State private var titleDraft: String = ""
    @State private var notesDraft: String = ""
    @State private var firstMoveDraft: String = ""
    @State private var loadedTaskID: UUID?
    @State private var requestNoteLinkOpen = false
    @FocusState private var focus: Field?

    enum Field: Hashable { case title, notes, subtaskAdd, firstMove }

    init(model: AppModel, previewTriageFill: TriageFillDisplay?? = nil, previewCalendarBlockExpanded: Bool = false) {
        self.model = model
        self.previewTriageFill = previewTriageFill
        self.previewCalendarBlockExpanded = previewCalendarBlockExpanded
    }

    private var task: KTask? {
        guard let id = model.selectedTaskID else { return nil }
        guard let t = model.store.task(id), t.deletedAt == nil else { return nil }
        return t
    }

    var body: some View {
        // Root cause of a prior calendar-unlink "does nothing" bug: every other screen that
        // re-derives from `model.store` after a mutation reads `model.version` so
        // `@Observable` knows to re-run `body` (SidebarScreen.swift, SidebarSavedViews.swift,
        // SidebarArchived.swift, MenuBarOrdoController.swift, QuickAddPanelView.swift all do
        // this explicitly) — `task` here is re-fetched fresh from `model.store` on every
        // `body` call, but nothing in this file ever read `model.version`, so `@Observable`
        // had no reason to call `body` again after `model.didMutate()` and the row kept
        // showing the pre-unlink state until some unrelated state change (a hover, a focus
        // change) happened to force a redraw.
        let _ = model.version
        Group {
            if let task {
                content(for: task)
            } else {
                KEmptyState(icon: "check-square",
                            title: String(localized: "detail.empty.title"),
                            message: String(localized: "detail.empty.body"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Tok.bg)
        // Commit any pending edit BEFORE the selection changes, so a keystroke never
        // lands on the wrong task and nothing typed is lost.
        .onChange(of: model.selectedTaskID) { oldID, _ in
            if let oldID { commitDrafts(for: oldID) }
            loadDrafts()
        }
        .onAppear { loadDrafts() }
        .onReceive(NotificationCenter.default.publisher(for: .kronosLinkNoteRequested)) { note in
            guard let taskID = note.userInfo?["taskID"] as? UUID else { return }
            model.selectedTaskID = taskID
            requestNoteLinkOpen = true
        }
    }

    private func content(for task: KTask) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.x4) {
                header(task)
                firstMoveSection(task)
                attributesRow(task)
                // One continuous borderless property list (style G): Status, Project,
                // Labels, Depth, Estimate, Repeat share the same label column and row
                // rhythm with no group boxes — a hairline is the only separator, and
                // only where the fields genuinely group (metadata vs. sizing vs. repeat).
                VStack(alignment: .leading, spacing: 0) {
                    InspectorStatusSection(model: model, task: task)
                    KHairline()
                    InspectorDepthEstimateSection(model: model, task: task)
                    KHairline()
                    InspectorRecurrenceSection(model: model, task: task)
                    KHairline()
                    VStack(alignment: .leading, spacing: 0) {
                        InspectorNoteLinkRow(model: model, task: task, requestOpen: $requestNoteLinkOpen)
                        InspectorContextLinksRow(model: model, task: task)
                    }
                }
                InspectorCalendarBlockRow(model: model, task: task, forceExpandedOnAppear: previewCalendarBlockExpanded)
                InspectorStepsSection(model: model, task: task)
                notesSection(task)
                if let rationale = task.triageRationale, !rationale.isEmpty {
                    rationalePanel(rationale)
                }
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
        .scrollDismissesKeyboard(.interactively)
        .onKeyPress(.escape) {
            commitDrafts(for: task.id)
            focus = nil
            NotificationCenter.default.post(name: Notification.Name("kronosFocusListRequested"), object: nil)
            return .handled
        }
        .onKeyPress(.return, phases: .down) { press in
            guard press.modifiers.contains(.command), focus != .notes else { return .ignored }
            toggleDone(task)
            return .handled
        }
    }

    // MARK: Header — completion + title + focus pin

    private func header(_ task: KTask) -> some View {
        VStack(alignment: .leading, spacing: Space.x1) {
            HStack(alignment: .top, spacing: Space.x2) {
                KCheckbox(isChecked: task.status == .done) { toggleDone(task) }
                    .padding(.top, Space.x1)
                TextField(String(localized: "detail.title.placeholder"), text: $titleDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Typo.display)
                    .tracking(Tracking.tight)
                    .foregroundStyle(Tok.textPrimary)
                    .lineLimit(1...6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focused($focus, equals: .title)
                    .onSubmit { commitTitle(task) }
                    .onChange(of: focus) { old, new in
                        if old == .title, new != .title { commitTitle(task) }
                    }
                    .kOnEscapeRevert(active: focus == .title) {
                        titleDraft = task.title
                        focus = nil
                    }
            }
            // KCheckbox's own layout width is Metrics.minHit (its hit-box), not its
            // visual circle size — using the circle's size here left this control 8pt
            // short of the title's actual x (caught in review: control at x=80, title
            // at x=100 in the 2x screenshot).
            HStack(spacing: Space.x3) {
                focusPinControl(task)
                InspectorRetriageControl(model: model, task: task)
            }
            .padding(.leading, Metrics.minHit + Space.x2)
            InspectorTriageFillRow(model: model, task: task, previewFill: previewTriageFill)
                .padding(.leading, Metrics.minHit + Space.x2)
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
    }

    private func toggleDone(_ task: KTask) {
        // Same helper the list row uses (Kronos/List/ListCompletion.swift) so completing from
        // the inspector raises the same shell-level undo pill everywhere.
        ListCompletion.toggle(task, store: model.store, model: model)
    }

    private func commitTitle(_ task: KTask) {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != task.title else {
            titleDraft = task.title
            return
        }
        model.store.update(task.id) { $0.title = trimmed }
        model.didMutate()
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
        let display = FirstMoveLogic.display(nextOpenSubtaskTitle: task.nextOpenSubtask?.title, firstMove: task.firstMove)
        return VStack(alignment: .leading, spacing: Space.x2) {
            InspectorSectionCaption(String(localized: "detail.firstmove"))
            KPanel {
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
                    case .editable:
                        TextField(String(localized: "detail.firstmove.placeholder"), text: $firstMoveDraft, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(Typo.body)
                            .foregroundStyle(Tok.textPrimary)
                            .lineLimit(1...4)
                            .focused($focus, equals: .firstMove)
                            .onSubmit { commitFirstMove(task) }
                            .onChange(of: focus) { old, new in
                                if old == .firstMove, new != .firstMove { commitFirstMove(task) }
                            }
                            .kOnEscapeRevert(active: focus == .firstMove) {
                                firstMoveDraft = task.firstMove ?? ""
                                focus = nil
                            }
                    }
                    Spacer(minLength: 0)
                }
                if task.dread {
                    HStack(spacing: Space.x1) {
                        Icon("heart", size: Metrics.iconS).foregroundStyle(Tok.textTertiary)
                        Text(String(localized: "detail.dread"))
                            .font(Typo.meta)
                            .foregroundStyle(Tok.textTertiary)
                    }
                    .padding(.top, Space.x2)
                }
            }
        }
    }

    private func commitFirstMove(_ task: KTask) {
        let trimmed = firstMoveDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (task.firstMove ?? "") else { return }
        model.store.setFirstMove(task.id, trimmed.isEmpty ? nil : trimmed)
        model.didMutate()
    }

    // MARK: Three first-class attributes

    /// Three equal-width labelled columns, one shared control height — an earlier inspector
    /// left this row unlabelled entirely. Each column's button face uses a SHORT value
    /// (KMenuButton's Menu label is `.fixedSize()` internally — a documented macOS quirk that
    /// cannot be worked around, so the face text must already be short rather than relying on
    /// truncation); the dropdown items underneath still show full names. Falls back to two
    /// rows only below ~300pt, where three real columns plus captions can't fit at all.
    private func attributesRow(_ task: KTask) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Space.x3) {
                effortColumn(task)
                deadlineColumn(task)
                priorityColumn(task)
            }
            VStack(spacing: Space.x3) {
                HStack(alignment: .top, spacing: Space.x3) {
                    effortColumn(task)
                    priorityColumn(task)
                }
                deadlineColumn(task)
            }
        }
    }

    private func effortColumn(_ task: KTask) -> some View {
        attributeColumn(caption: String(localized: "viewoptions.field.effort")) {
            KMenuButton(text: task.effort.shortDisplayName) {
                ForEach(KEffort.allCases) { option in
                    Button {
                        model.store.setEffort(task.id, option)
                        model.didMutate()
                    } label: {
                        if option == task.effort {
                            Label(option.displayName, systemImage: "checkmark")
                        } else {
                            Text(option.displayName)
                        }
                    }
                }
            } leading: {
                KEffortIndicator(level: task.effort.rawValue, of: 5, label: nil, showLabel: false)
            }
        }
    }

    private func priorityColumn(_ task: KTask) -> some View {
        attributeColumn(caption: String(localized: "viewoptions.field.priority")) {
            KMenuButton(text: task.priority.shortDisplayName) {
                ForEach(KPriority.allCases) { option in
                    Button {
                        model.store.setPriority(task.id, option)
                        model.didMutate()
                    } label: {
                        if option == task.priority {
                            Label(option.displayName, systemImage: "checkmark")
                        } else {
                            Text(option.displayName)
                        }
                    }
                }
            } leading: {
                KPriorityIndicator(level: task.priority.rawValue, of: 4, label: task.priority.displayName, size: 14)
            }
            .accessibilityLabel(String(localized: "viewoptions.field.priority"))
            .accessibilityValue(task.priority.displayName)
        }
    }

    private func deadlineColumn(_ task: KTask) -> some View {
        attributeColumn(caption: String(localized: "viewoptions.field.deadline")) {
            InspectorDeadlineControl(model: model, task: task)
        }
    }

    /// Style G: the three first-class attributes stay together on one row (never behind
    /// a disclosure), but the boxed control-per-column look from the old inspector is
    /// gone — a quiet hairline underline is the only boundary, no fill, no border box,
    /// matching the borderless property list below it rather than fighting it visually.
    private func attributeColumn<Content: View>(caption: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.x1) {
            Text(caption)
                .font(Typo.meta)
                .foregroundStyle(Tok.textTertiary)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: Metrics.controlCompact)
            KHairline()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Notes

    private func notesSection(_ task: KTask) -> some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            HStack {
                InspectorSectionCaption(String(localized: "detail.notes"))
                Spacer()
                // The same "Link Apple note" affordance also lives here, next to the notes
                // editor itself, not only on the note-link row above — hidden once a note is
                // already linked (that row above already owns Unlink).
                if NoteLink.find(in: task.notes) == nil {
                    Button {
                        requestNoteLinkOpen = true
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
            KTextArea(String(localized: "detail.notes.placeholder"), text: $notesDraft, minHeight: Metrics.controlRegular * 3)
                .focused($focus, equals: .notes)
                .onChange(of: focus) { old, new in
                    if old == .notes, new != .notes { commitNotes(task) }
                }
                .onChange(of: notesDraft) { _, _ in scheduleNotesAutosave(task) }
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
        let merged = InspectorNotesText.merging(visibleDraft: notesDraft, controlLinesFrom: task.notes)
        guard merged != task.notes else { return }
        model.store.update(task.id) { $0.notes = merged }
        model.didMutate()
    }

    // MARK: AI rationale

    private func rationalePanel(_ rationale: String) -> some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            InspectorSectionCaption(String(localized: "detail.rationale"))
            KPanel {
                HStack(alignment: .top, spacing: Space.x2) {
                    Icon("sparkles", size: Metrics.iconM).foregroundStyle(Tok.textTertiary)
                    Text(rationale)
                        .font(Typo.body)
                        .foregroundStyle(Tok.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Draft lifecycle

    private func loadDrafts() {
        guard let task else {
            loadedTaskID = nil
            titleDraft = ""
            notesDraft = ""
            firstMoveDraft = ""
            return
        }
        loadedTaskID = task.id
        titleDraft = task.title
        notesDraft = InspectorNotesText.visible(task.notes)
        firstMoveDraft = task.firstMove ?? ""
    }

    private func commitDrafts(for id: UUID) {
        guard let t = model.store.task(id) else { return }
        let trimmedTitle = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let mergedNotes = InspectorNotesText.merging(visibleDraft: notesDraft, controlLinesFrom: t.notes)
        let trimmedFirstMove = firstMoveDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = false
        model.store.update(id) { task in
            if !trimmedTitle.isEmpty, trimmedTitle != t.title { task.title = trimmedTitle; changed = true }
            if mergedNotes != t.notes { task.notes = mergedNotes; changed = true }
            // Only a task with no open subtask actually owns this field (FirstMoveLogic) —
            // committing it while a subtask is driving the display would silently overwrite
            // firstMove with a draft that was never shown as editable.
            if t.nextOpenSubtask == nil, trimmedFirstMove != (t.firstMove ?? "") {
                task.firstMove = trimmedFirstMove.isEmpty ? nil : trimmedFirstMove
                changed = true
            }
        }
        if changed { model.didMutate() }
        notesAutosaveWork?.cancel()
    }
}

