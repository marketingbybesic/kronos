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
    let onChooseDuplicate: (DuplicateChoice) -> Void
    @State private var titleText: String
    @State var notesText: String
    @State var newSubtaskText = ""
    /// Notes start collapsed to 2 lines (spec: "notes (2 lines, expandable, editable)") — a
    /// short first-move-sized hint, not a full editor taking over the row until the user
    /// deliberately asks for it.
    @State var isNotesExpanded = false
    /// Subtasks show "+N more" past 5 rather than always spelling out every one — a 12-subtask
    /// task (real scale, gate G4's `capture.review.big` fixture) must not push every row below
    /// it off screen. Starts collapsed; tapping "+N more" expands for the rest of this review
    /// session (not persisted — this whole screen is discarded on close).
    @State var isSubtasksExpanded = false
    /// The read display is a `Text` (2-line wrap + ellipsis); tapping it swaps in the
    /// single-line editable `TextField` this row already had, same commit path.
    @State private var isEditingTitle = false
    @FocusState private var isTitleFocused: Bool
    @FocusState var isNewSubtaskFocused: Bool

    init(row: CaptureRow, isSelected: Bool, projectNames: [String],
         onToggleTick: @escaping () -> Void, onSelect: @escaping () -> Void,
         onEditTitle: @escaping (String) -> Void,
         onPickProject: @escaping (String?) -> Void, onPickPriority: @escaping (KPriority) -> Void,
         onPickEffort: @escaping (KEffort) -> Void,
         onAddSubtask: @escaping (String) -> Void, onRemoveSubtask: @escaping (Int) -> Void,
         onEditNotes: @escaping (String) -> Void, onChooseDuplicate: @escaping (DuplicateChoice) -> Void) {
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
        self.onChooseDuplicate = onChooseDuplicate
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
        .uiTestAnchor("capture.review.row.\(row.proposal.title)")
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
                CaptureDuplicateChoices(row: row, onChoose: onChooseDuplicate)
            } else {
                projectColumn
                priorityColumn
                effortColumn
                deadlineColumn
                labelPills
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

    /// What the pasted line said that none of the pickers above shows: its `@label`s, as pills
    /// (`EntryText.pills(for:)` is the one place that reads a proposal as pills; project,
    /// priority, effort and due keep their pickers and the deadline text).
    @ViewBuilder
    private var labelPills: some View {
        ForEach(EntryText.pills(for: row.proposal).filter { $0.slot == .label }, id: \.self) { pill in
            KBadge(EntryFormat.pillText(pill), tint: Tok.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: 180, alignment: .leading)
                .uiTestAnchor("capture.row.pill.label")
        }
    }

    private var accessibilityLabel: String {
        var parts = [row.proposal.title]
        if let project = row.proposal.projectName { parts.append(project) }
        parts.append(contentsOf: row.proposal.labelNames)
        parts.append(CapturePriorityOption(row.proposal.priority).title)
        parts.append(CaptureEffortOption(row.proposal.effort).title)
        if row.proposal.isDuplicateOfOpenTask { parts.append(String(localized: "capture.row.duplicate")) }
        parts.append(contentsOf: row.subtasks)
        return parts.joined(separator: ", ")
    }

}

// MARK: - Identifiable option wrappers.
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
