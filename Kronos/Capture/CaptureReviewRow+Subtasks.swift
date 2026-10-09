// Kronos/Capture/CaptureReviewRow+Subtasks.swift
// The proposed-subtasks list (with its connector line) and the notes field below a capture
// review row: split out of CaptureReviewRow.swift to keep that file inside the 500-line limit.
import SwiftUI
import KronosCore

extension CaptureReviewRow {
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
    private static let kListRowOuterInset: CGFloat = 6
    static let subtaskMarkerX: CGFloat = kListRowOuterInset + Metrics.listRowLeading + Metrics.listCheckboxSize + Metrics.listCheckboxTitleGap
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

    var subtaskSection: some View {
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
                .uiTestAnchor("capture.review.sub.\(title)")
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
    /// No debounce: this row is in-memory review state only (nothing on disk until Create).
    @ViewBuilder
    var notesSection: some View {
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
