// Kronos/Capture/CaptureModel.swift
// Drives the paste -> extract -> review flow. Runs the deterministic `NoteSplitter` pass
// synchronously so the review list appears instantly, then — when AI is on — replaces
// untouched rows in place once the model's reply lands, never reordering or dropping a row
// the user has already edited (spec: "never reorder or drop rows the user already edited").
import Foundation
import KronosCore

@MainActor
@Observable
final class CaptureModel {
    enum Step { case paste, review, done }

    private let model: AppModel
    private(set) var step: Step = .paste
    var noteText: String = ""
    /// Set by `kronosCaptureFromFolderRequested` for an Apple-Notes-kind project folder
    /// (CaptureScreen.swift) so the paste step opens straight into that folder's notes
    /// instead of requiring "From Apple Notes" and picking the folder by hand.
    var notesSourceFolder: NoteFolderInfo?
    private(set) var rows: [CaptureRow] = []
    private(set) var droppedLineCount = 0
    private(set) var isDeterministic = true
    private(set) var createdCount = 0
    /// Quiet one-line status while an AI upgrade is in flight. Never a spinner.
    private(set) var isUpgrading = false
    /// WHY `isDeterministic` is what it is, or which model answered — the status line must
    /// never render nothing. Nil only before the first `findTasks()`/`improveWithAI()` call
    /// resolves; `CaptureReviewList`'s status line reads this (never `isDeterministic` alone)
    /// so every outcome renders exactly one line — a prior bug went silently blank on an
    /// all-rejected reply.
    private(set) var extractReason: ExtractReason?
    /// Which model is currently being asked, shown as "Asking <model>…" while `isUpgrading` —
    /// set right before the request starts, read only by the status line.
    private(set) var askingModel: String?

    private var extractTask: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
    }

    var tickedCount: Int { rows.filter(\.isTicked).count }

    /// The create button must count what it will ACTUALLY create, same as the header counts
    /// what was found — only ticked rows' subtasks, since an unticked row's subtasks are never
    /// created either (`create()` only calls `addSubtasks` for `acceptedRows`, below).
    var tickedSubtaskCount: Int { rows.filter(\.isTicked).reduce(0) { $0 + $1.subtasks.count } }

    // MARK: AI visibility — a switch the user can actually see and flip, not just the quiet
    // in-flight status line.

    /// True once the app delegate has wired a router in (Settings > AI, mode != .off, a working
    /// key). Nil means every AI affordance below hides — there is nothing to switch on.
    var isAIAvailable: Bool { model.ai != nil }

    /// `AIRouter` (KronosCore, public) is the sole shipped `AIRouting` implementation — reading
    /// its own `candidates.first`'s `modelID` through this cast is a public-API read, not a
    /// reach into a frozen contract type; `AIRouting` itself carries no model name (deliberately
    /// thin), so this is the only place one exists.
    /// A fixture router in snapshots/tests is not an `AIRouter` and reads as nil here, same as
    /// AI being off — the paste view's fallback text covers both cases identically.
    var aiModelName: String? { (model.ai as? AIRouter)?.candidates.first?.client.modelID }

    /// The user's switch: on means `findTasks()`/`improveWithAI()` call the router; off runs
    /// NoteSplitter alone even though a router is configured. Persisted (CapturePrefs, hermetic
    /// under KRONOS_SNAPSHOT), default on so shipped behaviour is unchanged until the user
    /// deliberately turns it off.
    var useAI: Bool {
        get { CapturePrefs.useAI }
        set { CapturePrefs.useAI = newValue }
    }

    /// Every proposed row counts here, ticked or not, since this is "what did we find in the
    /// text", not "what will be created" (that is `tickedCount`, used by the create button).
    var subtaskCount: Int { rows.reduce(0) { $0 + $1.subtasks.count } }

    var projectNames: [String] {
        model.store.allProjects().map(\.name)
    }

    private var today: Int { Day.today(calendar: KronosLocale.calendar) }

    private var existingOpenTitles: [String] {
        model.store.allTasks().filter { KStatus.open.contains($0.status) }.map(\.title)
    }

    // MARK: Step 1 -> 2

    /// Runs the deterministic split immediately (pure, sync), shows the review list, then —
    /// if AI is configured — kicks off the improving pass in the background. Subtasks come
    /// from `TaskOutline`'s indent/bullet grammar (via `NoteSplitter.subtasks(in:)`), keyed by
    /// each proposal's own `sourceLine` — the same key `upgrade(with:)` already matches AI
    /// replies on. Notes come from `NoteSplitter.notes(in:)` the same way, straight onto
    /// `proposal.notes` — `ProposedTask` already carries that field and
    /// `TaskStore+Capture.createMany` already writes it.
    func findTasks() {
        let text = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let deterministic = NoteSplitter.split(text, today: today, projectNames: projectNames)
        let marked = AIRouter_markDuplicatesLocally(deterministic, existingOpenTitles: existingOpenTitles)
        let outlineSubtasks = NoteSplitter.subtasks(in: text, projectNames: projectNames)
        let outlineNotes = NoteSplitter.notes(in: text, projectNames: projectNames)
        rows = marked.map { proposal in
            var proposal = proposal
            proposal.notes = outlineNotes[proposal.sourceLine]
            return CaptureRow(proposal: proposal, subtasks: outlineSubtasks[proposal.sourceLine] ?? [])
        }
        droppedLineCount = max(0, deterministic.count - NoteSplitter.maxProposals)
        isDeterministic = true
        step = .review

        guard useAI else {
            // The switch being off skips the AI call even if configured — the status line must
            // still say so explicitly; nothing renders "nothing".
            extractReason = .aiOff
            return
        }
        runAIExtraction(on: text)
    }

    /// An explicit "Improve with AI" action on the review step, not just the automatic pass
    /// `findTasks()` already kicks off — lets a user who turned the switch off (or whose first
    /// pass never reached AI: `model.ai` was nil, now configured) ask for it once without
    /// re-pasting. Re-runs the SAME extraction over the original note text; the result lands
    /// through `upgrade(with:)`, which already only touches untouched rows, so a row already
    /// edited by hand is never clobbered.
    func improveWithAI() {
        let text = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, model.ai != nil, !isUpgrading else { return }
        runAIExtraction(on: text)
    }

    private func runAIExtraction(on text: String) {
        guard let ai = model.ai else {
            extractReason = .noModel   // the switch is on but nothing is configured to ask.
            return
        }
        isUpgrading = true
        askingModel = aiModelName
        extractTask?.cancel()
        extractTask = Task { [weak self] in
            let result = await ai.extractTasks(from: text, projectNames: self?.projectNames ?? [],
                                               existingOpenTitles: self?.existingOpenTitles ?? [], today: self?.today ?? 0)
            guard !Task.isCancelled else { return }
            self?.upgrade(with: result)
        }
    }

    /// Thin call into `CaptureMerge.merge` (KronosCore, AI/CaptureMerge.swift): the actual merge
    /// logic is a pure Core function, unit-tested there (two real defects were found and fixed
    /// reviewing it — see that file's own header). This method's only job is converting
    /// `[CaptureRow]` <-> `[CaptureMergeRow]` at the boundary, since `CaptureRow` lives in the
    /// app target and Core cannot import it.
    private func upgrade(with result: ExtractResult) {
        isUpgrading = false
        isDeterministic = result.isDeterministic
        extractReason = result.reason
        askingModel = nil
        droppedLineCount = result.droppedLineCount
        guard !result.isDeterministic else { return }

        let mergeRows = rows.map {
            CaptureMergeRow(id: $0.id, proposal: $0.proposal, isTicked: $0.isTicked,
                            isEdited: $0.isEdited, subtasks: $0.subtasks)
        }
        let merged = CaptureMerge.merge(rows: mergeRows, aiTasks: result.tasks)
        rows = merged.map {
            // `id: $0.id` (not the default `proposal.id`): a row whose proposal was REPLACED by
            // an AI task keeps ITS OWN id, matching `CaptureMergeRow`'s id, not the AI task's —
            // see `CaptureRow.init`'s own doc comment for why this matters (selection tracking).
            var row = CaptureRow(id: $0.id, proposal: $0.proposal, subtasks: $0.subtasks)
            row.isTicked = $0.isTicked
            row.isEdited = $0.isEdited
            return row
        }
    }

    // MARK: Editing (review step)

    func setTicked(_ id: UUID, _ ticked: Bool) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].isTicked = ticked
        rows[i].isEdited = true
    }

    func update(_ id: UUID, _ mutate: (inout ProposedTask) -> Void) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        mutate(&rows[i].proposal)
        rows[i].isEdited = true
    }

    /// Appends one subtask to a proposed task's own list from the review step, not just from
    /// the outline. Blank input is ignored — never an empty subtask title.
    func addSubtask(_ id: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].subtasks.append(trimmed)
        rows[i].isEdited = true
    }

    /// Removes one proposed subtask by its index in that row's own list — the review row shows
    /// them as a plain indented, editable list, same remove-by-index shape as an already-created
    /// task's subtask list elsewhere in the app.
    func removeSubtask(_ id: UUID, at index: Int) {
        guard let i = rows.firstIndex(where: { $0.id == id }), rows[i].subtasks.indices.contains(index) else { return }
        rows[i].subtasks.remove(at: index)
        rows[i].isEdited = true
    }

    func selectAll() { for i in rows.indices { rows[i].isTicked = true } }
    func selectNone() { for i in rows.indices { rows[i].isTicked = false } }

    // MARK: Back to paste

    func backToPaste() {
        step = .paste
    }

    // MARK: Create

    /// Creates every ticked row's task AND its subtasks in ONE undo step: subtasks must be as
    /// integrated as the task itself, not a separate action. `createMany` and `addSubtasks`
    /// each register their own `groupedUndo` step; wrapping both in this one
    /// collapses them into a single step (`TaskStore.groupedUndo`: "Nesting is safe — an inner
    /// call joins the outer group"), so Cmd-Z after accepting 5 tasks with subtasks removes
    /// all of it in one keystroke, same as accepting 5 tasks with none.
    func create() {
        let acceptedRows = rows.filter(\.isTicked)
        guard !acceptedRows.isEmpty else { return }
        let defaultProject: KProject? = {
            guard case .project(let id) = model.scope else { return nil }
            return model.store.allProjects(includeArchived: true).first { $0.id == id }
        }()
        model.store.groupedUndo("Create Tasks") {
            let created = model.store.createMany(acceptedRows.map(\.proposal), defaultProject: defaultProject)
            // `createMany` returns tasks in the same order as its input (Store/TaskStore+Capture.swift
            // iterates `for proposal in proposals { ... created.append(task) }`), so zipping by
            // index pairs each accepted row with the task made from its own proposal.
            for (row, task) in zip(acceptedRows, created) where !row.subtasks.isEmpty {
                model.store.addSubtasks(row.subtasks, to: task.id)
            }
        }
        model.didMutate()
        createdCount = acceptedRows.count
        step = .done
    }

    func close() {
        extractTask?.cancel()
        model.isCaptureOpen = false
    }
}

/// Mirrors `AIRouter.markDuplicates` (internal to KronosCore) for the deterministic-only
/// path, which this screen must run without ever touching an AI router. Kept tiny and local
/// rather than widening Core's public surface for one call site.
private func AIRouter_markDuplicatesLocally(_ proposals: [ProposedTask], existingOpenTitles: [String]) -> [ProposedTask] {
    let foldedOpen = Set(existingOpenTitles.map(KTextFold.fold))
    return proposals.map { p in
        var p = p
        p.isDuplicateOfOpenTask = foldedOpen.contains(KTextFold.fold(p.title))
        return p
    }
}
