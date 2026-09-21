// Kronos/Capture/CaptureReviewRow.swift
// One editable proposed-task row: tick, title (tap to edit, up to 2 lines), and a quieter
// attributes line below it (project · priority · effort · due — or the duplicate note, which
// wins when both would apply).
//
// At the real 520 pt host, fixed-width trailing columns sharing ONE row with the title left it
// only ~250 pt wide — hard-truncated with NO ellipsis. The title now gets the row's full width
// (2 lines, tail ellipsis) and attributes moved below (where first-move/duplicate already
// lived). Priority/effort stay built directly (mirrors ListRowView.priorityMenu/effortMenu:
// `Menu` label = `Color.clear` at a fixed frame, real indicator as a non-hit-testing overlay)
// — a text menu label's ideal width drifts per row.
import SwiftUI
import KronosCore

/// Fixed sizes for the priority/effort glyphs (mirrors ListRowView's `SlotWidth`) — everything
/// else on the attributes line sizes to its own content.
enum CaptureSlotWidth {
    static let priority: CGFloat = 22
    static let effort: CGFloat = 44
}

struct CaptureReviewRow: View {
    let row: CaptureRow
    let isSelected: Bool
    let projectNames: [String]
    let onToggleTick: () -> Void
    let onSelect: () -> Void
    let onEditTitle: (String) -> Void
    let onPickProject: (String?) -> Void
    let onPickPriority: (KPriority) -> Void
    let onPickEffort: (KEffort) -> Void
    /// Subtasks proposed alongside a task (from the pasted outline, or typed by hand here) must
    /// be visible and editable before anything is created — remove one, add one — same as
    /// `InspectorBreakdownPreview`'s own accept-before-commit preview.
    let onAddSubtask: (String) -> Void
    let onRemoveSubtask: (Int) -> Void
    /// The notes `NoteSplitter`/the AI extract prompt already attach to `row.proposal.notes`
    /// must be visible and editable before creation, same principle as subtasks below.
    let onEditNotes: (String) -> Void

    @State private var titleText: String
    @State private var notesText: String
    @State private var newSubtaskText = ""
    /// Notes start collapsed to 2 lines (spec: "notes (2 lines, expandable, editable)") — a
    /// short first-move-sized hint, not a full editor taking over the row until the user
    /// deliberately asks for it.
    @State private var isNotesExpanded = false
    /// Subtasks show "+N more" past 5 rather than always spelling out every one — a 12-subtask
    /// task (real scale, gate G4's `capture.review.big` fixture) must not push every row below
    /// it off screen. Starts collapsed; tapping "+N more" expands for the rest of this review
    /// session (not persisted — this whole screen is discarded on close).
    @State private var isSubtasksExpanded = false
    /// The read display is a `Text` (2-line wrap + ellipsis); tapping it swaps in the
    /// single-line editable `TextField` this row already had, same commit path.
    @State private var isEditingTitle = false
    @FocusState private var isTitleFocused: Bool
    @FocusState private var isNewSubtaskFocused: Bool

    init(row: CaptureRow, isSelected: Bool, projectNames: [String],
         onToggleTick: @escaping () -> Void, onSelect: @escaping () -> Void,
         onEditTitle: @escaping (String) -> Void,
         onPickProject: @escaping (String?) -> Void, onPickPriority: @escaping (KPriority) -> Void,
         onPickEffort: @escaping (KEffort) -> Void,
         onAddSubtask: @escaping (String) -> Void, onRemoveSubtask: @escaping (Int) -> Void,
         onEditNotes: @escaping (String) -> Void) {
        self.row = row
        self.isSelected = isSelected
        self.projectNames = projectNames
        self.onToggleTick = onToggleTick
        self.onSelect = onSelect
        self.onEditTitle = onEditTitle
        self.onPickProject = onPickProject
        self.onPickPriority = onPickPriority
        self.onPickEffort = onPickEffort
        self.onAddSubtask = onAddSubtask
        self.onRemoveSubtask = onRemoveSubtask
        self.onEditNotes = onEditNotes
        self._titleText = State(initialValue: row.proposal.title)
        self._notesText = State(initialValue: row.proposal.notes ?? "")
    }

    /// Tall enough for a 2-line title PLUS the attributes line below it, at every row — a
    /// taller row for one task must not shift every row below it. Scales with `DSScale.text`
    /// like `Typo.row`/`Typo.meta` do, or Text size L would clip line 2.
    private static var rowDensity: CGFloat {
        Metrics.rowHeight + Metrics.rowHeight * 0.72 * DSScale.text + Space.x1 + Space.x2
    }

    var body: some View {
        // Subtasks render BELOW the row rather than inside KListRow's own fixed-height slot
        // (KListRow is a frozen contract component and folds its content into one
        // fixed-height accessibility row) — a variable-count list needs a sibling, not a slot.
        VStack(alignment: .leading, spacing: 0) {
            KListRow(isSelected: isSelected, density: Self.rowDensity, isChecked: row.isTicked,
                     accessibilityLabel: accessibilityLabel,
                     onToggle: onToggleTick, onSelect: onSelect) {
                titleColumn
            }
            subtaskSection
            notesSection
        }
        .onChange(of: row.proposal.title) { _, newValue in
            if titleText != newValue { titleText = newValue }
        }
        .onChange(of: row.proposal.notes) { _, newValue in
            let newValue = newValue ?? ""
            if notesText != newValue { notesText = newValue }
        }
    }

    // MARK: Title + attributes line

    /// The title gets the row's full width, up to 2 lines, tail-ellipsis past that. `Text` for
    /// READ display, not an always-on `TextField(axis: .vertical)`:
    /// `KListRow`'s row is a FIXED-height HStack, and a multi-line field inside it clipped to
    /// one line with no ellipsis (`InspectorScreen.swift:133`'s identical field wraps fine, but
    /// sits in a free VStack). `Text.lineLimit(2)` truncates correctly since it never needs to
    /// grow the container. Tap swaps in the same single-line field this row always had.
    private var titleColumn: some View {
        VStack(alignment: .leading, spacing: Space.x1) {
            if isEditingTitle {
                TextField(String(localized: "capture.row.title.placeholder"), text: $titleText)
                    .textFieldStyle(.plain)
                    .font(Typo.row)
                    .foregroundStyle(row.isTicked ? Tok.textPrimary : Tok.textTertiary)
                    .lineLimit(1)
                    .focused($isTitleFocused)
                    .onSubmit { commitTitleEdit() }
                    .onChange(of: isTitleFocused) { wasFocused, isFocused in
                        if wasFocused, !isFocused { commitTitleEdit() }
                    }
                    .onAppear { isTitleFocused = true }
            } else {
                Text(row.proposal.title)
                    .font(Typo.row)
                    .foregroundStyle(row.isTicked ? Tok.textPrimary : Tok.textTertiary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(); isEditingTitle = true }
            }
            attributesLine
        }
    }

    private func commitTitleEdit() {
        isEditingTitle = false
        onEditTitle(titleText)
    }

    /// project · priority · effort · due, or "Already in your list" alone when duplicate (wins
    /// over attributes). First move dropped here: no room for a 3rd line, and attributes are
    /// what must be checked before Create — the first move shows later, in the inspector.
    private var attributesLine: some View {
        HStack(spacing: Space.x2) {
            if row.proposal.isDuplicateOfOpenTask {
                Text(String(localized: "capture.row.duplicate"))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                    .lineLimit(1)
            } else {
                projectColumn
                priorityColumn
                effortColumn
                deadlineColumn
                Spacer(minLength: 0)
            }
        }
        // Reserves the line's height in EITHER branch — no always-present sibling may collapse
        // to zero and shift the next row — the duplicate branch has no fixed-size glyph of its
        // own to hold the height the way priorityColumn/effortColumn's `Metrics.iconM` frame
        // already does in the other branch.
        .frame(minHeight: Metrics.iconM, alignment: .leading)
    }

    /// `KMenuButton` (not a raw `Menu`) — a raw `Menu`'s own label is re-measured/clipped to a
    /// tiny hit-test width by `.menuStyle(.borderlessButton)` (confirmed: "Acme" rendered as
    /// "A"); `KMenuButton` composes its text OUTSIDE the `Menu` itself, avoiding that. No fixed
    /// width now: no shared column x across rows to hold anymore.
    private var projectColumn: some View {
        KMenuButton(text: row.proposal.projectName ?? String(localized: "sidebar.inbox")) {
            projectMenuItems
        }
    }

    @ViewBuilder
    private var projectMenuItems: some View {
        Button {
            onPickProject(nil)
        } label: {
            if row.proposal.projectName == nil { Label(String(localized: "sidebar.inbox"), systemImage: "checkmark") }
            else { Text(String(localized: "sidebar.inbox")) }
        }
        ForEach(projectNames, id: \.self) { name in
            Button {
                onPickProject(name)
            } label: {
                if row.proposal.projectName == name { Label(name, systemImage: "checkmark") }
                else { Text(name) }
            }
        }
    }

    /// Bars only, no name text ("No priority" spelled out on most rows read as noise) — same
    /// construction as ListRowView.priorityMenu. No extra dimming on top: `KPriorityIndicator`
    /// already draws an unfilled bar at 18% white, which alone says "none" — stacking another
    /// opacity multiplier on top made it nearly invisible on true black.
    private var priorityColumn: some View {
        Menu {
            ForEach(KPriority.allCases, id: \.self) { p in
                Button {
                    onPickPriority(p)
                } label: {
                    if p == row.proposal.priority { Label(CapturePriorityOption(p).title, systemImage: "checkmark") }
                    else { Text(CapturePriorityOption(p).title) }
                }
            }
        } label: {
            Color.clear.frame(width: Metrics.iconM, height: Metrics.iconM)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .overlay {
            KPriorityIndicator(level: row.proposal.priority.rawValue, of: 4,
                               label: CapturePriorityOption(row.proposal.priority).title, size: 14)
                .allowsHitTesting(false)
        }
        .frame(width: CaptureSlotWidth.priority, alignment: .leading)
        .help(CapturePriorityOption(row.proposal.priority).title)
    }

    /// Dots + short code (XS…XL) when set — unlike priority, the size code is compact enough
    /// not to be the noise the full priority word was. `.none` hides its label text
    /// (`showLabel:` below) but keeps the dots at their own built-in dimness — same reasoning
    /// as priority just above.
    private var effortColumn: some View {
        Menu {
            ForEach(KEffort.allCases, id: \.self) { e in
                Button {
                    onPickEffort(e)
                } label: {
                    if e == row.proposal.effort { Label(CaptureEffortOption(e).title, systemImage: "checkmark") }
                    else { Text(CaptureEffortOption(e).title) }
                }
            }
        } label: {
            Color.clear.frame(width: Metrics.iconM, height: Metrics.iconM)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .overlay(alignment: .leading) {
            KEffortIndicator(level: row.proposal.effort.rawValue, of: 5,
                             label: CaptureEffortOption(row.proposal.effort).title,
                             showLabel: row.proposal.effort != .none)
                .allowsHitTesting(false)
        }
        .frame(width: CaptureSlotWidth.effort, alignment: .leading)
        .help(CaptureEffortOption(row.proposal.effort).title)
    }

    /// No fixed width now: this line sizes to its own content, no shared column x across rows
    /// to hold — empty due date shows nothing at all rather than a dash placeholder, since an
    /// empty attributes line already reads as quiet on its own here (unlike the old
    /// trailing-column layout, where every row needed the same slot count to keep every OTHER
    /// row's columns from drifting).
    @ViewBuilder
    private var deadlineColumn: some View {
        if let day = row.proposal.dueDay {
            KDeadlineLabel(text: CaptureDeadlineFormatter.short(day: day))
        }
    }

    private var accessibilityLabel: String {
        var parts = [row.proposal.title]
        if let project = row.proposal.projectName { parts.append(project) }
        parts.append(CapturePriorityOption(row.proposal.priority).title)
        parts.append(CaptureEffortOption(row.proposal.effort).title)
        if row.proposal.isDuplicateOfOpenTask { parts.append(String(localized: "capture.row.duplicate")) }
        parts.append(contentsOf: row.subtasks)
        return parts.joined(separator: ", ")
    }

    // MARK: Subtasks

    /// Subtasks previously read as orphan rows, not nested under their parent — the marker sat
    /// LEFT of the parent title (under the checkbox), with the same gap to the parent as
    /// between two unrelated tasks. Two measured x's from KListRow's own geometry (KListRow.swift's
    /// header comment + Tokens.swift), from this VStack's own left edge (it is a sibling of
    /// KListRow, same coordinate space). `kListRowOuterInset` (6) is KListRow's own
    /// `.padding(.horizontal, 6)` — hardcoded there (a file this leaf does not own), no
    /// `Space`/`Metrics` token matches it, so it is named here rather than left a bare literal:
    ///   checkbox CENTRE = kListRowOuterInset (6) + Metrics.sidebarSelectionBarWidth (2, the
    ///     gutter) + (Metrics.listRowLeading (12) - that gutter) + half the checkbox
    ///     (Metrics.listCheckboxSize / 2) = 6+2+10+8 = 26.
    ///   title START = kListRowOuterInset (6) + Metrics.listRowLeading (12) +
    ///     Metrics.listCheckboxSize (16) + Metrics.listCheckboxTitleGap (10) = 44.
    /// The subtask marker now sits at the TITLE's x (44): marker at the title's x, text after
    /// it; a thin vertical connector runs from the checkbox centre (26) down to the last
    /// visible subtask row, drawn as one overlay behind the whole group rather than per-row, so
    /// it reads as one continuous line, not dashed segments.
    private static let kListRowOuterInset: CGFloat = 6
    private static let subtaskMarkerX: CGFloat = kListRowOuterInset + Metrics.listRowLeading + Metrics.listCheckboxSize + Metrics.listCheckboxTitleGap
    private static let connectorX: CGFloat = kListRowOuterInset + Metrics.sidebarSelectionBarWidth
        + (Metrics.listRowLeading - Metrics.sidebarSelectionBarWidth) + Metrics.listCheckboxSize / 2

    /// Existing subtasks (from the outline, or added by hand) always show, so they are visible
    /// without selecting every row first — that IS the feature; the "add subtask" line only
    /// appears once this row is selected, so an unselected task with no subtasks stays exactly
    /// as quiet as it is today (30 rows each showing an idle input field would be decoration
    /// without a job). Past this many, the rest collapse behind "+N more".
    private static let visibleSubtaskLimit = 5

    private var visibleSubtaskCount: Int {
        isSubtasksExpanded ? row.subtasks.count : min(row.subtasks.count, Self.visibleSubtaskLimit)
    }

    private var subtaskSection: some View {
        // Tight to the parent row (Space.x1, was already the group's own top inset via
        // `.padding(.leading...)`'s sibling spacing in the outer VStack — the GAP to the NEXT
        // task after this group stays the list's own Space.x1 row spacing, unchanged, so only
        // the parent-to-subtask distance tightens, exactly what "reads as orphan" needed.
        VStack(alignment: .leading, spacing: Space.x1) {
            ForEach(Array(row.subtasks.enumerated().prefix(visibleSubtaskCount)), id: \.offset) { index, title in
                HStack(spacing: Space.x2) {
                    // Dashed circle, not a real KCheckbox: matches InspectorBreakdownPreview's
                    // own draftRow marker for "proposed, not yet a real subtask" — a task is
                    // not created until this whole row is ticked and accepted, so a subtask
                    // here isn't independently completable yet either.
                    Circle()
                        .strokeBorder(Tok.textDisabled, style: StrokeStyle(lineWidth: Metrics.strokeQuiet, dash: [2, 2]))
                        .frame(width: Metrics.iconXS, height: Metrics.iconXS)
                    Text(title)
                        .font(Typo.meta)
                        .foregroundStyle(Tok.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: Space.x2)
                    Button { onRemoveSubtask(index) } label: {
                        Icon("x", size: Metrics.iconXS)
                    }
                    .kButton(.icon, size: .compact)
                    .accessibilityLabel(String(localized: "common.delete"))
                }
                .frame(minHeight: Metrics.controlCompact)
            }
            if !isSubtasksExpanded, row.subtasks.count > Self.visibleSubtaskLimit {
                let remaining = row.subtasks.count - Self.visibleSubtaskLimit
                Button {
                    isSubtasksExpanded = true
                } label: {
                    Text(String(format: String(localized: "capture.row.subtask.more"), remaining))
                        .font(Typo.meta)
                        .foregroundStyle(Tok.textTertiary)
                }
                .buttonStyle(.plain)
                .frame(minHeight: Metrics.controlCompact, alignment: .leading)
            }
            if isSelected {
                HStack(spacing: Space.x2) {
                    Icon("plus", size: Metrics.iconXS).foregroundStyle(Tok.textTertiary)
                    TextField(String(localized: "capture.row.subtask.add"), text: $newSubtaskText)
                        .textFieldStyle(.plain)
                        .font(Typo.meta)
                        .foregroundStyle(Tok.textTertiary)
                        .focused($isNewSubtaskFocused)
                        .onSubmit(commitNewSubtask)
                        .onChange(of: isNewSubtaskFocused) { wasFocused, isFocused in
                            if wasFocused, !isFocused { commitNewSubtask() }
                        }
                }
                .frame(minHeight: Metrics.controlCompact)
            }
        }
        .padding(.leading, Self.subtaskMarkerX)
        // The subtask remove "x" previously ended short of the task row's own trailing content
        // (dash/badges) above it — Space.x1 (4) here vs. KListRow's own Metrics.listRowTrailing
        // (12) inset before ITS trailing content, an 8pt mismatch. Matching KListRow's own
        // trailing inset puts every "x" on the same right edge as the row's own trailing
        // column, which is itself already the same right edge as the header/footer content
        // (all three width Space.x5 from the card's outer bound).
        .padding(.trailing, Metrics.listRowTrailing)
        .padding(.bottom, row.subtasks.isEmpty && !isSelected ? 0 : Space.x1)
        .background(alignment: .topLeading) {
            // The connector: one continuous line from just under the parent checkbox down to
            // the vertical centre of the LAST visible subtask row — never drawn when there is
            // nothing to connect (no subtasks yet, unselected row), so an idle task never grows
            // a stray line. `GeometryReader` inside the background reads this VStack's own
            // measured height, so the line always ends exactly at the last row regardless of
            // how many are visible or whether "+N više"/the add-field is showing.
            if !row.subtasks.isEmpty {
                GeometryReader { proxy in
                    Rectangle()
                        .fill(Tok.textDisabled.opacity(0.35))
                        .frame(width: Metrics.strokeQuiet)
                        .frame(width: Self.subtaskMarkerX, alignment: .leading)
                        .offset(x: Self.connectorX)
                        .frame(height: max(0, connectorHeight(in: proxy.size)))
                }
            }
        }
    }

    /// The connector's own length: from the top of this background (level with the parent
    /// checkbox's bottom edge) down to the vertical centre of the LAST visible subtask row —
    /// stops there, never runs into "+N više"/the add-subtask field below it.
    private func connectorHeight(in size: CGSize) -> CGFloat {
        guard visibleSubtaskCount > 0 else { return 0 }
        let rowHeight = Metrics.controlCompact + Space.x1   // one subtask row + its own group spacing
        return CGFloat(visibleSubtaskCount - 1) * rowHeight + Metrics.controlCompact / 2
    }

    private func commitNewSubtask() {
        let trimmed = newSubtaskText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onAddSubtask(trimmed)
        newSubtaskText = ""
    }

    // MARK: Notes

    /// Editable once selected (matches "add subtask"); read-only + 2-line-clamped otherwise.
    /// `KTextArea` has no focus/submit hook, but this row is in-memory review state only
    /// (nothing on disk until Create), so committing every keystroke needs no debounce.
    @ViewBuilder
    private var notesSection: some View {
        if !(row.proposal.notes ?? "").isEmpty || isSelected {
            VStack(alignment: .leading, spacing: Space.x1) {
                if isSelected {
                    KTextArea(String(localized: "capture.row.notes.placeholder"), text: $notesText,
                              minHeight: Metrics.controlCompact * (isNotesExpanded ? 4 : 2))
                        .onChange(of: notesText) { _, newValue in onEditNotes(newValue) }
                    if !isNotesExpanded, notesText.components(separatedBy: .newlines).count > 2 || notesText.count > 120 {
                        Button(String(localized: "capture.row.notes.more")) { isNotesExpanded = true }
                            .buttonStyle(.plain)
                            .font(Typo.meta)
                            .foregroundStyle(Tok.textTertiary)
                    }
                } else if let notes = row.proposal.notes, !notes.isEmpty {
                    Text(notes).font(Typo.meta).foregroundStyle(Tok.textTertiary).lineLimit(2)
                }
            }
            .padding(.leading, Self.subtaskMarkerX)
            .padding(.trailing, Metrics.listRowTrailing)
            .padding(.bottom, Space.x1)
        }
    }
}

// MARK: - Identifiable option wrappers
//
// KronosCore's `KPriority` and `KEffort` are plain raw-value enums (by design — the design
// system must not depend on KronosCore types), so their menu labels are read through these
// thin per-screen wrappers rather than widening either module's public surface.

private struct CapturePriorityOption: Identifiable, Hashable {
    let value: KPriority
    var id: Int { value.rawValue }
    var title: String {
        switch value {
        case .none: String(localized: "priority.none")
        case .low: String(localized: "priority.low")
        case .medium: String(localized: "priority.medium")
        case .high: String(localized: "priority.high")
        case .urgent: String(localized: "priority.urgent")
        }
    }
    init(_ value: KPriority) { self.value = value }
}

private struct CaptureEffortOption: Identifiable, Hashable {
    let value: KEffort
    var id: Int { value.rawValue }
    var title: String {
        switch value {
        case .none: String(localized: "effort.none")
        case .xs: String(localized: "effort.xs")
        case .s: String(localized: "effort.s")
        case .m: String(localized: "effort.m")
        case .l: String(localized: "effort.l")
        case .xl: String(localized: "effort.xl")
        }
    }
    init(_ value: KEffort) { self.value = value }
}

/// Mirrors the palette leaf's own short relative-date formatting approach (KronosLocale-aware,
/// no dependency on another leaf's internals).
enum CaptureDeadlineFormatter {
    static func short(day: Int) -> String {
        let date = KronosCore.Day.date(day, calendar: KronosLocale.calendar)
        let formatter = DateFormatter()
        formatter.locale = KronosLocale.current
        formatter.calendar = KronosLocale.calendar
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter.string(from: date)
    }
}
