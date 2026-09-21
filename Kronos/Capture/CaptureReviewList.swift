// Kronos/Capture/CaptureReviewList.swift
// Step 2: an editable checklist of proposed tasks. Up/Down moves the keyboard selection,
// Space toggles the selected row's tick, Return edits its title, Cmd-Return creates
// (handled one level up, in CaptureScreen, since it is the screen's one primary action).
import SwiftUI
import KronosCore

struct CaptureReviewList: View {
    @Bindable var capture: CaptureModel
    @State private var selectedID: UUID?
    @FocusState private var isListFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            KHairline()
            if capture.rows.isEmpty {
                emptyState
            } else {
                list
            }
            KHairline()
            footer
        }
        .onAppear { selectedID = capture.rows.first?.id; isListFocused = true }
        .focusable(true)
        .focusEffectDisabled()
        .focused($isListFocused)
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.space) { toggleSelected(); return .handled }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            HStack {
                Text(String(localized: "capture.review.title"))
                    .font(Typo.heading)
                    .foregroundStyle(Tok.textPrimary)
                // The counts sit right next to the title, the first thing read in this step,
                // not buried in the create button below.
                Text(countLine)
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                Spacer()
                HStack(spacing: Space.x3) {
                    quietTextButton(String(localized: "capture.review.select_all")) { capture.selectAll() }
                    quietTextButton(String(localized: "capture.review.select_none")) { capture.selectNone() }
                }
            }
            statusLine
        }
        .padding(.horizontal, Space.x5)
        .padding(.top, Space.x4)
        .padding(.bottom, Space.x3)
    }

    /// "4 tasks · 9 subtasks" — omits the subtasks half when nothing proposed any subtasks, so
    /// a plain flat list (the common case) reads as one clean count rather than "4 tasks · 0
    /// subtasks".
    ///
    /// A prior version called `String(format: tasksPattern, locale:, n)` against a SINGLE
    /// string holding all 3 Croatian plural forms concatenated ("%lld zadatak / %lld zadatka /
    /// %lld zadataka") with only one format argument supplied for three %lld — the missing
    /// 2nd/3rd varargs read garbage stack memory, printing numbers like
    /// "−2.086.367.757.894.298.622 zadataka". `KPlural.hr` (Kronos/Shared/KPlural.swift) picks
    /// the one correct string (`<key>.one`/`.few`/`.many`, each holding exactly one %lld) via the
    /// CLDR-hr rule instead of trying to cram all categories into one pattern.
    private var countLine: String { Self.pluralCountLine(tasks: capture.rows.count, subtasks: capture.subtaskCount) }

    /// "Create 7 tasks · 2 subtasks" — the button must count what it will actually create,
    /// ticked rows only, same shared plural formatter the header count uses
    /// (`tickedSubtaskCount`, not `subtaskCount`: an unticked row's subtasks are never created
    /// either).
    private var createButtonLabel: String {
        let count = Self.pluralCountLine(tasks: capture.tickedCount, subtasks: capture.tickedSubtaskCount)
        return "\(String(localized: "capture.action.create_label")) \(count)"
    }

    /// Shared by the header count and the create button, so both count what will actually be
    /// created (including subtasks) the same way — same literal-key KPlural pattern either
    /// caller needs, kept in one place so there is exactly one "N tasks · M subtasks" formatter
    /// rather than two copies that could drift.
    private static func pluralCountLine(tasks: Int, subtasks: Int) -> String {
        let tasksPart = KPlural.hr(tasks,
                                   one: String(localized: "capture.review.count.tasks.one"),
                                   few: String(localized: "capture.review.count.tasks.few"),
                                   many: String(localized: "capture.review.count.tasks.many"))
        guard subtasks > 0 else { return tasksPart }
        let subtasksPart = KPlural.hr(subtasks,
                                      one: String(localized: "capture.review.count.subtasks.one"),
                                      few: String(localized: "capture.review.count.subtasks.few"),
                                      many: String(localized: "capture.review.count.subtasks.many"))
        return "\(tasksPart) · \(subtasksPart)"
    }

    // The status line ALWAYS renders exactly one of four states below — never nothing. A prior
    // bug went silently blank on an all-rejected AI reply (`isDeterministic` flipped to `false`
    // with an empty `remaining` array and no branch here covered it). `capture.extractReason`
    // (not `isDeterministic` alone) now drives every branch.
    @ViewBuilder
    private var statusLine: some View {
        if capture.isUpgrading {
            // A progress state that survives the 15-20 s a real call can take — this text just
            // stays up for as long as `isUpgrading` is true, no timeout of its own, no spinner
            // theatre (matches InspectorBreakdownPreview's own "Thinking…").
            Text(askingText)
                .font(Typo.meta)
                .foregroundStyle(Tok.textTertiary)
        } else {
            switch capture.extractReason {
            case .ai(let model):
                Text(String(format: String(localized: "capture.status.ai_named"), model))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
            case .aiOff:
                // An explicit action here, not only the automatic pass `findTasks()` already
                // tried. Same "Improve with AI" wording as before: turning the switch off is
                // not a failure, so this keeps its original action label, not "Retry".
                HStack(spacing: Space.x2) {
                    Text(String(localized: "capture.status.ai_off"))
                        .font(Typo.meta)
                        .foregroundStyle(Tok.textTertiary)
                    if capture.isAIAvailable {
                        Button(String(localized: "capture.ai.improve")) { capture.improveWithAI() }
                            .buttonStyle(.plain)
                            .font(Typo.meta)
                            .foregroundStyle(Tok.textSecondary)
                    }
                }
            case .noModel, .transport, .emptyAnswer, .allRejected, nil:
                // `nil` only precedes the very first `findTasks()`/`improveWithAI()` resolving —
                // reads as the same calm "plain split" row a real failure does, never blank.
                // "Retry" (not "Improve with AI"): this branch means AI was actually asked and
                // came back unusable — the action re-asks the SAME way, worded as a retry.
                HStack(spacing: Space.x2) {
                    Text(failedText)
                        .font(Typo.meta)
                        .foregroundStyle(Tok.textTertiary)
                    if capture.isAIAvailable {
                        Button(String(localized: "capture.ai.retry")) { capture.improveWithAI() }
                            .buttonStyle(.plain)
                            .font(Typo.meta)
                            .foregroundStyle(Tok.textSecondary)
                    }
                }
            }
            if capture.droppedLineCount > 0 {
                Text(String(format: String(localized: "capture.status.dropped"), capture.droppedLineCount))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
            }
        }
    }

    private var askingText: String {
        guard let model = capture.askingModel else { return String(localized: "capture.status.improving") }
        return String(format: String(localized: "capture.status.asking"), model)
    }

    /// "AI failed: <reason>. Plain split shown." — the reason string is a short, calm label per
    /// `ExtractReason` case, never a raw provider error string shown to the user (`.transport`'s
    /// associated `AIError.description` is log-only, read from the eval/report, never surfaced
    /// here).
    private var failedText: String {
        let reasonKey: String
        switch capture.extractReason {
        case .noModel:               reasonKey = "capture.status.reason.no_model"
        case .transport:             reasonKey = "capture.status.reason.transport"
        case .emptyAnswer:           reasonKey = "capture.status.reason.empty"
        case .allRejected:           reasonKey = "capture.status.reason.rejected"
        case .ai, .aiOff, nil:       reasonKey = "capture.status.reason.unknown"
        }
        return String(format: String(localized: "capture.status.failed"), String(localized: String.LocalizationValue(reasonKey)))
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: Space.x1) {
                ForEach(capture.rows) { row in
                    CaptureReviewRow(
                        row: row, isSelected: row.id == selectedID, projectNames: capture.projectNames,
                        onToggleTick: { selectedID = row.id; capture.setTicked(row.id, !row.isTicked) },
                        onSelect: { selectedID = row.id },
                        onEditTitle: { newTitle in
                            capture.update(row.id) { $0.title = newTitle }
                        },
                        onPickProject: { name in
                            capture.update(row.id) { $0.projectName = name }
                        },
                        onPickPriority: { priority in
                            capture.update(row.id) { $0.priority = priority }
                        },
                        onPickEffort: { effort in
                            capture.update(row.id) { $0.effort = effort }
                        },
                        onAddSubtask: { title in
                            capture.addSubtask(row.id, title: title)
                        },
                        onRemoveSubtask: { index in
                            capture.removeSubtask(row.id, at: index)
                        },
                        onEditNotes: { notes in
                            capture.update(row.id) { $0.notes = notes.isEmpty ? nil : notes }
                        })
                    .id(row.id)
                }
            }
            // The list's own rows sat one level inset from the header/footer above and below
            // them (Space.x3 here vs. Space.x5 on `header`/`footer`), so nothing shared one
            // left edge. Matching the header/footer inset puts every row's checkbox at the
            // same x as the title above it.
            .padding(.horizontal, Space.x5)
            .padding(.vertical, Space.x2)
        }
    }

    private var emptyState: some View {
        KEmptyState(icon: "inbox", title: String(localized: "capture.review.empty"))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Space.x3) {
            Button(String(localized: "capture.action.back")) { capture.backToPaste() }
                .kButton(.secondary)
            Spacer()
            KKeyHint("⌘", "⏎")
            Button(createButtonLabel) {
                capture.create()
            }
            .kButton(.primary)
            .disabled(capture.tickedCount == 0)
        }
        .padding(.horizontal, Space.x5)
        .padding(.vertical, Space.x3)
    }

    /// A quiet text-only affordance for a secondary header action — deliberately NOT
    /// `.kButton`, whose every kind renders its label at `Tok.textPrimary` and would compete
    /// with the screen title (select all/none previously read as "primary white" and floated
    /// far apart). Matches the plain-text-button pattern CommandPaletteView's own `keymapRow`
    /// already uses for a one-off control no design-system component covers.
    private func quietTextButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Typo.meta)
                .foregroundStyle(Tok.textSecondary)
        }
        .buttonStyle(.plain)
        .frame(minHeight: Metrics.minHit)
    }

    // MARK: Keyboard

    private func move(_ delta: Int) {
        guard !capture.rows.isEmpty else { return }
        let ids = capture.rows.map(\.id)
        let currentIndex = selectedID.flatMap { ids.firstIndex(of: $0) } ?? 0
        let count = ids.count
        let next = ((currentIndex + delta) % count + count) % count
        selectedID = ids[next]
    }

    private func toggleSelected() {
        guard let selectedID, let row = capture.rows.first(where: { $0.id == selectedID }) else { return }
        capture.setTicked(selectedID, !row.isTicked)
    }
}
