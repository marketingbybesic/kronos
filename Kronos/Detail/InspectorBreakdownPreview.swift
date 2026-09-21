// BREAK DOWN — inspector preview. Not a subtask until the user commits.
// Deterministic proposal (`DeterministicBreakdown.steps`, pure, sync) renders
// IMMEDIATELY; if `model.ai` is set, its improved reply replaces the rows in
// place — but only while the user hasn't touched the proposal yet, matching
// the capture screen's "silent unless it would lose something" rule. Accept
// appends via `TaskStoring.addSubtasks` (ONE undo step) and never edits
// what's already there; Discard throws the draft away.
import SwiftUI
import KronosCore

struct InspectorBreakdownPreview: View {
    let model: AppModel
    let task: KTask
    /// Existing subtask titles at the moment the preview opened — passed to
    /// AI as the "don't repeat these" set and used for the local guard too.
    let existingSubtaskTitles: [String]
    var onClose: () -> Void

    @State private var steps: [Draft] = []
    @State private var firstMove: String = ""
    @State private var offerFirstMove = false
    @State private var setFirstMoveOnAccept = true
    @State private var isDeterministic = true
    @State private var isWaitingForAI = false
    @State private var userEdited = false
    @FocusState private var focusedStepID: UUID?

    /// Snapshot-only seam: skip `.task` and drive the preview from a fixed
    /// result instead, so the harness never touches AIRouter's async path.
    var previewResult: BreakdownResult?

    struct Draft: Identifiable {
        let id = UUID()
        var title: String
    }

    private var nonEmptyCount: Int {
        steps.filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    var body: some View {
        // No panel box: a top hairline reads this as a continuation of the steps
        // section above it rather than a nested card — a panel-inside-panel look was
        // flagged in review. Rows carry their own quiet identity (dashed marker,
        // secondary tone) instead of a container doing it for them.
        VStack(alignment: .leading, spacing: Space.x2) {
            KHairline()
            statusLine
            VStack(spacing: 0) {
                ForEach($steps) { $step in
                    draftRow($step)
                }
            }
            addBlankRow
            if offerFirstMove {
                firstMoveOffer
            }
            actions
        }
        .padding(.top, Space.x1)
        .task {
            if let previewResult {
                apply(previewResult, markWaitingDone: true)
            } else {
                await load()
            }
        }
    }

    // MARK: Rows

    /// Deliberately QUIETER than a real subtask row (`InspectorStepsSection.stepRow`),
    /// never brighter: no fill (a real row's KCheckbox has a fill-on-hover; this marker
    /// never fills), a dashed hairline outline rather than KCheckbox's solid quiet-at-
    /// rest ring, secondary text tone (real rows use primary) — but the columns
    /// (marker centre, text x) are IDENTICAL to a real subtask row, not just the same
    /// row height, so a proposal previews exactly where it will land once accepted
    /// (caught in review: this row was missing stepRow's own `Space.x1` outer padding
    /// and its marker had no Metrics.minHit hit-box frame, so the marker sat ~9pt left
    /// of the real checkbox's centre instead of matching it).
    private func draftRow(_ step: Binding<Draft>) -> some View {
        HStack(spacing: Space.x2) {
            Circle()
                .strokeBorder(Tok.textDisabled, style: StrokeStyle(lineWidth: Metrics.strokeQuiet, dash: [2, 2]))
                .frame(width: Metrics.iconL, height: Metrics.iconL)
                .frame(width: Metrics.minHit, height: Metrics.minHit)
            TextField(String(localized: "detail.subtasks.add"), text: step.title)
                .textFieldStyle(.plain)
                .font(Typo.row)
                .foregroundStyle(Tok.textSecondary)
                .focused($focusedStepID, equals: step.wrappedValue.id)
                .onChange(of: step.wrappedValue.title) { _, _ in userEdited = true }
            Spacer(minLength: Space.x2)
            Button {
                userEdited = true
                steps.removeAll { $0.id == step.wrappedValue.id }
            } label: {
                Icon("x", size: Metrics.iconXS)
            }
            .kButton(.icon, size: .compact)
            .accessibilityLabel(String(localized: "common.delete"))
        }
        .frame(height: Metrics.rowHeight)
        .padding(.horizontal, Space.x1)
    }

    private var addBlankRow: some View {
        Button {
            userEdited = true
            let draft = Draft(title: "")
            steps.append(draft)
            focusedStepID = draft.id
        } label: {
            HStack(spacing: Space.x2) {
                Icon("plus", size: Metrics.iconS).foregroundStyle(Tok.textTertiary)
                Text(String(localized: "detail.subtasks.add"))
                    .font(Typo.row)
                    .foregroundStyle(Tok.textTertiary)
            }
        }
        .buttonStyle(.plain)
        .frame(height: Metrics.controlCompact)
    }

    private var firstMoveOffer: some View {
        Button { setFirstMoveOnAccept.toggle() } label: {
            HStack(spacing: Space.x2) {
                KCheckbox(isChecked: setFirstMoveOnAccept, size: Metrics.statusCircle) {
                    setFirstMoveOnAccept.toggle()
                }
                Text(String(format: String(localized: "detail.breakdown.setfirstmove"), firstMove))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textSecondary)
                    .lineLimit(2)
            }
            // Same Space.x1 outer inset as stepRow/draftRow, so this checkbox's own
            // Metrics.minHit hit box lands on the same columns as every other checkbox
            // row in this pane and the text after it shares their x too.
            .padding(.horizontal, Space.x1)
        }
        .buttonStyle(.plain)
    }

    // MARK: Status line — quiet, one line, no spinner theatre.

    private var statusLine: some View {
        HStack(spacing: Space.x1) {
            if isWaitingForAI {
                Text(String(localized: "detail.breakdown.thinking"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
            } else if isDeterministic {
                Text(String(localized: "detail.breakdown.no_ai"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
            }
        }
        .animation(Motion.curve(Motion.fast), value: isWaitingForAI)
    }

    // MARK: Actions

    private var acceptButton: some View {
        Button(String(format: String(localized: "detail.breakdown.add_n"), nonEmptyCount)) {
            accept()
        }
        .kButton(.primary, size: .compact)
        .disabled(nonEmptyCount == 0)
        .keyboardShortcut(.return, modifiers: .command)
    }

    private var discardButton: some View {
        Button(String(localized: "detail.breakdown.discard")) { onClose() }
            .kButton(.ghost, size: .compact)
    }

    /// A long HR translation (strings here run up to 2x EN) can outgrow a
    /// single row at the inspector's narrow minimum width — ViewThatFits
    /// drops to a stacked, primary-on-top layout rather than truncating,
    /// mirroring InspectorScreen.attributesRow's own fallback.
    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.x2) {
                discardButton
                Spacer()
                acceptButton
            }
            VStack(alignment: .trailing, spacing: Space.x2) {
                acceptButton
                discardButton
            }
        }
        .kOnEscapeRevert(active: true) { onClose() }
    }

    // MARK: Loading

    private func load() async {
        // Matches AIRouter.breakdown's own detection: from the task's text,
        // never the UI locale.
        let language = detectLanguage(task.title)
        let context = await notesWithLinkedNoteContext()
        let deterministic = DeterministicBreakdown.steps(title: task.title, notes: context, language: language)
        apply(deterministic, markWaitingDone: false)

        guard let ai = model.ai else { return }
        isWaitingForAI = true
        let result = await ai.breakdown(title: task.title, notes: context, existingSubtasks: existingSubtaskTitles)
        isWaitingForAI = false
        // The user already started editing the deterministic draft — keep
        // their edits, drop the late AI result rather than clobber them.
        guard !userEdited else { return }
        apply(result, markWaitingDone: true)
    }

    /// Feature F.3: when this task links an Apple Note (`NoteLink`), its plain-text body is
    /// fetched fresh and appended to the notes text handed to the breakdown pass — never
    /// persisted onto the task itself (the stored state stays just the one `notes://` line;
    /// re-fetching here means an edit in Notes is always picked up, not a stale copy). Missing
    /// access, a timeout, or no link at all all fall back to the task's own notes unchanged —
    /// breakdown must still work exactly as before for a task with no linked note.
    private func notesWithLinkedNoteContext() async -> String {
        guard let noteID = NoteLink.find(in: task.notes) else { return task.notes }
        guard let body = try? await model.notes.body(ofNoteID: noteID), !body.isEmpty else { return task.notes }
        return task.notes + "\n\n" + body
    }

    private func apply(_ result: BreakdownResult, markWaitingDone: Bool) {
        if markWaitingDone { isWaitingForAI = false }
        steps = result.subtasks.map { Draft(title: $0) }
        firstMove = result.firstMove
        isDeterministic = result.isDeterministic
        offerFirstMove = !firstMove.isEmpty && (task.firstMove?.isEmpty ?? true)
    }

    private func accept() {
        let titles = steps.map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !titles.isEmpty else { return }
        if offerFirstMove, setFirstMoveOnAccept {
            model.store.groupedUndo(String(localized: "detail.breakdown")) {
                model.store.addSubtasks(titles, to: task.id)
                model.store.setFirstMove(task.id, firstMove)
            }
        } else {
            model.store.addSubtasks(titles, to: task.id)
        }
        model.didMutate()
        onClose()
    }
}
