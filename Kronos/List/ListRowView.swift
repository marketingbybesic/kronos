// Kronos/List/ListRowView.swift
// One task row: checkbox, title, fixed-order trailing slots (priority, effort, deadline,
// project glyph, subtask progress, recurrence), inline attribute editing, subtask
// disclosure, drag reorder (Manual sort only), context menu. Built on KListRow.
//
// Driver review round 2 (2026-09-19): trailing slots must occupy a FIXED width each so
// columns align down the list regardless of which attributes a given row has set; an
// unset attribute renders nothing by default and only reveals a faint hover affordance
// rather than a "None"/dash placeholder; priority shows its bars glyph only (name moves
// to tooltip + accessibilityLabel) and draws NOTHING at all for `.none`; an earlier date shows
// as the date it was, muted, with no verdict word (ListDueText.swift).
//
// Round-2 defects fixed here (both measured in screenshots, not guessed):
// 1. The deadline slot's `.frame(width:)` was a proposal, not a hard constraint: the
//    outer `slots` HStack had `.fixedSize(horizontal: true, vertical: false)`, which asks
//    every child for its OWN ideal width and lays out at that — completely bypassing the
//    per-slot `.frame(width:)` I'd set. A carry-pill row and a no-deadline row therefore
//    reported different ideal widths and every column after the deadline slot shifted.
//    Fixed by dropping `.fixedSize` from the row entirely (a plain HStack respects a
//    child's own `.frame(width:)` as a hard constraint) and widening `SlotWidth.deadline`
//    to fit the widest real content (a carry pill) so populated/empty slots measure equal.
// 2. `KPriority.none` still drew four dim bars — there was no early-out for it at all.
import SwiftUI
import KronosCore

/// Fixed widths for each trailing slot, declared once here so every row's columns land at
/// the same x regardless of which attributes that particular task has set — a slot with
/// nothing to show keeps its width and renders empty (or a faint hover affordance) rather
/// than collapsing and shifting every column after it. `deadline` is sized for the widest
/// content it ever shows ("Tomorrow" + no pill, or a short relative date + an "Nd" carry
/// pill) so a populated and an empty deadline slot measure identically.
enum SlotWidth {
    static let priority: CGFloat = 22
    static let effort: CGFloat = 44
    static let deadline: CGFloat = 64
    static let project = Metrics.iconM
    static let subtasks: CGFloat = 34
    static let recurrence = Metrics.iconS

    /// Total trailing-slot width for a given column mode, gaps included — the single
    /// source both the width-class decision (TaskListScreen) and the row's own layout
    /// (ListRowView) read, so they can never disagree about what fits.
    static func totalWidth(for mode: ColumnMode) -> CGFloat {
        let gap = Metrics.listTrailingSlotGap
        var w = priority + gap + effort + gap + deadline
        if mode.showsProject { w += gap + project }
        if mode.showsSubtasks { w += gap + subtasks }
        if mode.showsRecurrence { w += gap + recurrence }
        return w
    }
}

/// Which optional trailing slots the list currently has room for. Computed ONCE for the
/// whole list from its measured width (TaskListScreen, via GeometryReader) and passed down
/// to every row — never decided per row. Per-row fitting (e.g. `ViewThatFits` per instance)
/// let two rows in the same list independently choose different variants depending on their
/// OWN content width, which broke column alignment exactly like the unconstrained slot
/// widths did: two rows must always agree on which columns exist.
enum ColumnMode: Equatable {
    case full           // recurrence + subtasks + project
    case noRecurrence    // subtasks + project
    case noSubtasks      // project only
    case minimal         // none of the three

    var showsRecurrence: Bool { self == .full }
    var showsSubtasks: Bool { self == .full || self == .noRecurrence }
    var showsProject: Bool { self != .minimal }

    /// Picks the richest mode whose total slot width fits `available` (the row's trailing
    /// content budget), falling back progressively — recurrence first, then subtasks, then
    /// the project glyph, in that priority order.
    static func fitting(available: CGFloat) -> ColumnMode {
        for mode: ColumnMode in [.full, .noRecurrence, .noSubtasks, .minimal] {
            if SlotWidth.totalWidth(for: mode) <= available { return mode }
        }
        return .minimal
    }
}

struct ListRowView: View {
    @Bindable var model: AppModel
    let task: KTask
    let ctx: ListContext
    let isSelected: Bool
    let showProjectGlyph: Bool
    /// Which optional trailing slots this list currently fits — computed ONCE for the
    /// whole list (TaskListScreen) and identical for every row, so columns never disagree.
    let columnMode: ColumnMode
    let onSelect: () -> Void

    @State private var subtasksExpanded = false
    @FocusState private var focusedSubID: UUID?   // the step row that has keyboard focus (Cmd-[ acts on it)
    @State private var showDeadlinePopover = false
    @State private var showProjectPicker = false   // key P
    @State private var isHovering = false
    @State var isEditingTitle = false   // Title edit; not private — ListRowTitleEdit.swift needs it.
    @State var editedTitle = ""
    @FocusState var titleFieldFocused: Bool
    @Environment(\.chromaMode) private var chromaMode
    @Environment(\.kAccent) private var accent
    static var snapshotEditingTaskID: UUID?   // Snapshot-only trigger, set by ListSnapshots.

    private var today: Int { Day.today() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row.uiTestAnchor("row." + task.title)
            if subtasksExpanded {
                let labelMatches = Set(task.childrenCarryingAnyLabel(of: ctx.markedLabelIDs).map(\.id))
                ForEach(task.orderedChildren, id: \.id) { sub in
                    ChildTaskRow(model: model, child: sub, parent: task, isDriver: task.isDueDriver(sub),
                                 isLabelMatch: labelMatches.contains(sub.id),
                                 columnMode: columnMode, focus: $focusedSubID) {
                        if model.selectedTaskID != task.id { onSelect() }
                    }
                    .uiTestAnchor("subrow." + sub.title)
                }
                inlineAddSubtask
            }
        }
        .onAppear {
            if task.id == ListRowView.snapshotEditingTaskID { beginTitleEdit() }
            revealLabelledChildren()
        }
        .onChange(of: ctx.markedLabelIDs) { _, _ in revealLabelledChildren() }
    }

    /// Under a label filter, a row listed only because a child carries the label opens its
    /// children, so the marked child is visible (the row alone would not say why it is here).
    private func revealLabelledChildren() {
        let ids = ctx.markedLabelIDs
        guard !subtasksExpanded, !ids.isEmpty, !task.carriesAnyLabel(of: ids),
              !task.childrenCarryingAnyLabel(of: ids).isEmpty else { return }
        subtasksExpanded = true
    }

    private var row: some View {
        KListRow(isSelected: isSelected, isDone: task.status == .done, isChecked: task.status == .done,
                  accessibilityLabel: accessibilityLabel, accessibilityValue: accessibilityValue,
                  selectionTint: SelectionHue.forTask(task, neutral: chromaMode.isNeutralSelection).color(accent: accent),
                  onToggle: { ListCompletion.toggle(task, store: model.store, model: model) },
                  onSelect: onSelect) {
            HStack(spacing: Space.x1) {
                // Fixed left gutter: the chevron (or nothing) always takes the same width, so titles
                // align whether or not a row has subtasks.
                ZStack {
                    Color.clear.frame(width: Metrics.minHit, height: Metrics.minHit)
                    if !task.orderedChildren.isEmpty {
                        Button {
                            withAnimation(Motion.curve(Motion.fast)) { subtasksExpanded.toggle() }
                        } label: {
                            Icon("chevron-right", size: Metrics.iconXS)
                                .foregroundStyle(Tok.textTertiary)
                                // Rotates in place instead of swapping glyphs: a disclosure
                                // triangle hinging open reads as one continuous motion (the
                                // native macOS pattern), not a pop between two unrelated SF
                                // Symbols. Reuses the `withAnimation` already wrapping the
                                // toggle above — no new animation primitive.
                                .rotationEffect(.degrees(subtasksExpanded ? 90 : 0))
                                .frame(minWidth: Metrics.minHit, minHeight: Metrics.minHit)
                                .contentShape(Rectangle())   // inside the label: the glyph alone is a 10 pt target
                        }
                        .buttonStyle(.plain)
                        .uiTestAnchor("arrow." + task.title)
                    }
                }
                titleView
                attachmentIndicators
                blockedGlyph
                agentDoneGlyph
                delegatedGlyph
                workingGlyph
            }
        } trailing: {
            trailingSlots
        }
        // Dragging works in every sort mode (nest and move-under do not depend on the order); the list's
        // one AppKit drop destination (DropOverlayView) decides what a drop means, see DropZoneController.
        .onDrag { DragOut.provider(task: task) }
        .reportsDropRow(id: task.id)
        .contentShape(Rectangle())   // whole row answers a right click, selected or not
        .kTaskContextMenu(task, model: model, onSelect: onSelect, pickDue: { showDeadlinePopover = true })
        .followsExpandAll($subtasksExpanded, hasSubtasks: !task.orderedChildren.isEmpty)
        .onHover { isHovering = $0 }
        .animation(Motion.curve(Motion.fast), value: isHovering)
    }

    /// A lock after the title while the task still waits on open tasks; the tooltip names the one
    /// it waits on, or counts them. Gone as soon as the last open blocker is done or removed.
    @ViewBuilder private var blockedGlyph: some View {
        let _ = model.version   // blockers are other tasks: re-read after any store change
        let blockers = KStatus.open.contains(task.status) ? model.store.openBlockers(of: task.id) : []
        if !blockers.isEmpty {
            let text = blockers.count == 1
                ? String(format: String(localized: "list.row.blocked.one"), blockers[0].waitsOnDisplayName)
                : String(format: String(localized: "list.row.blocked.many"), blockers.count)
            Icon("lock.fill", size: Metrics.iconXS, weight: .medium)
                .foregroundStyle(Tok.textSecondary)
                .help(text)
                .accessibilityLabel(text)
                .uiTestAnchor("row.blocked." + task.title)
        }
    }


    // MARK: - Trailing slots (fixed order: priority · effort · deadline · project · subtasks ·
    // recurrence). Each slot has a fixed width (`SlotWidth`) so columns align down the list
    // regardless of which attributes a given row has set. `columnMode` (identical for every
    // row in the list, computed once by TaskListScreen from the measured list width) decides
    // which optional slots exist here — NOT a per-row `ViewThatFits`, which let two rows
    // disagree about which columns exist and broke alignment. No `.fixedSize` on this
    // HStack: each slot's own `.frame(width:)` must be a hard constraint the parent
    // respects, not a proposal a `.fixedSize` ideal-width pass overrides.
    private var trailingSlots: some View {
        HStack(spacing: Metrics.listTrailingSlotGap) {
            // The two RARE slots lead the block: most tasks have neither, and as trailing slots they
            // used to leave ~90 pt of dead space right of the project glyph on every row.
            if columnMode.showsSubtasks {
                subtaskProgressSlot
            }
            if columnMode.showsRecurrence {
                recurrenceSlot
            }
            priorityMenu
            effortMenu
            deadlineControl
            if showProjectGlyph && columnMode.showsProject {
                projectSlot
            }
        }
    }

    // Round-3 fix: every one of these was `Group { if <condition> { content } }` with no
    // final `else` — when the condition is false the Group renders ZERO views, and SwiftUI
    // collapsed that empty Group to zero width even with `.frame(width:)` applied to it
    // (the same bug just fixed in `deadlineControl`). A row with a visible subtasks badge
    // or recurrence glyph therefore had a WIDER trailing block than a row without one, and
    // since `KListRow` right-anchors the whole trailing block behind a `Spacer`, a wider
    // block on one row shifted every slot in THAT row — including priority, upstream of
    // subtasks/recurrence — relative to a row whose block was narrower. Fixed the same way:
    // an always-present `Color.clear` of the slot's own size, so the Group's ideal size
    // never depends on which branch (if any) is active.
    private var projectSlot: some View {
        ZStack {
            Color.clear.frame(width: SlotWidth.project, height: Metrics.iconM)
            if let project = task.project {
                KProjectGlyph(icon: project.icon, color: rowGlyphColor(for: project), isFocus: task.id == model.focusTaskID, size: Metrics.iconM, carrier: .rowGlyph)
            }
        }
    }

    /// "Colour by" (feature I): project stays the project's own hex; priority/effort override
    /// it with a fixed palette mapping; none is always neutral. A plain `switch` statement
    /// cannot live inside a `@ViewBuilder` closure (it reads as view-building syntax there, not
    /// an ordinary statement), hence this being a separate function rather than inline above.
    private func rowGlyphColor(for project: KProject) -> Color {
        switch AppearancePrefs.colourBy.resolvedColor(priorityLevel: task.priority.rawValue, effortLevel: task.effort.rawValue) {
        case .useProjectColor:
            return Color(hexString: project.colorHex)
        case .override(let c):
            return c
        case .neutral:
            return Tok.textSecondary
        }
    }

    private var subtaskProgressSlot: some View {
        ZStack(alignment: .trailing) {
            Color.clear.frame(width: SlotWidth.subtasks, height: 1)
            if !task.orderedChildren.isEmpty {
                let progress = task.subtaskProgress
                KBadge("\(progress.done)/\(progress.total)")
            }
        }
    }

    private var recurrenceSlot: some View {
        ZStack {
            Color.clear.frame(width: SlotWidth.recurrence, height: Metrics.iconS)
            if task.recurrenceRule != nil {
                Icon("repeat", size: Metrics.iconS).foregroundStyle(Tok.textTertiary)
            }
        }
    }

    /// Priority shows its bars glyph ONLY — the word "High"/"Medium" moves to the tooltip and
    /// `KPriorityIndicator`'s own accessibilityLabel/Value, since a
    /// visible name on every row was the noise the toolbar rebuild was meant to remove.
    /// `KAttributeMenu` always shows its `title` as visible menu-button text, so this menu
    /// is built directly rather than through it — two things went wrong before this landed:
    /// (1) a Shape-drawn glyph placed directly IN a Menu's `label:` renders nothing at all
    /// (the bug `KMenuButton`'s doc comment describes); (2) using an `Image(systemName:)`
    /// with `.opacity(0)` as a decoy label does NOT stay invisible — `.menuStyle(.borderlessButton)`
    /// re-renders the label as its own template image and ignores the composited opacity,
    /// so the "invisible" flag glyph showed through behind the bars. Fixed by making the
    /// Menu's own label a plain `Color.clear` (no glyph for the button style to re-draw)
    /// and drawing the real indicator as a non-hit-testing overlay sibling.
    private var priorityMenu: some View {
        Menu {
            ForEach(KPriority.allCases, id: \.self) { p in
                Button {
                    guard task.priority != p else { return }
                    model.store.setPriority(task.id, p)
                    model.commit(String(format: String(localized: "undo.priority.name"), ViewOptionsMapper.priorityName(p), task.title))
                } label: {
                    if p == task.priority { Label(ViewOptionsMapper.priorityName(p), systemImage: "checkmark") }
                    else { Text(ViewOptionsMapper.priorityName(p)) }
                }
            }
        } label: {
            Color.clear.frame(width: Metrics.iconM, height: Metrics.iconM)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .overlay {
            KPriorityIndicator(level: task.priority.rawValue, of: 4, label: ViewOptionsMapper.priorityName(task.priority), size: 14)
                .allowsHitTesting(false)
        }
        .frame(width: SlotWidth.priority, alignment: .trailing)
        .help(ViewOptionsMapper.priorityName(task.priority))
        // Calm rows (F6): bars at rest only for high and urgent; every other level is a hover-only
        // affordance so the menu stays reachable.
        .opacity(task.priority == .high || task.priority == .urgent || isHovering ? 1 : 0)
    }

    /// Effort dots draw only for a set effort (F6: no five empty slots on every row); an unset one
    /// is a hover-only affordance. Same glyph-outside-the-label fix as `priorityMenu` above.
    private var effortMenu: some View {
        Menu {
            ForEach(KEffort.allCases, id: \.self) { e in
                Button {
                    guard task.effort != e else { return }
                    model.store.setEffort(task.id, e)
                    model.commit(String(format: String(localized: "list.pill.effort"), ViewOptionsMapper.effortName(e), task.title))
                } label: {
                    if e == task.effort { Label(ViewOptionsMapper.effortName(e), systemImage: "checkmark") }
                    else { Text(ViewOptionsMapper.effortName(e)) }
                }
            }
        } label: {
            Color.clear.frame(width: Metrics.iconM, height: Metrics.iconM)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .overlay {
            KEffortIndicator(level: task.effort.rawValue, of: 5, label: ViewOptionsMapper.effortName(task.effort), showLabel: task.effort != .none)
                .allowsHitTesting(false)
                .opacity(task.effort != .none || isHovering ? 1 : 0)
        }
        .frame(width: SlotWidth.effort, alignment: .trailing)
        .help(ViewOptionsMapper.effortName(task.effort))
    }

    /// No deadline: nothing shows at rest, a faint hairline hint appears on row hover so the
    /// slot stays discoverable/clickable without adding permanent noise. An earlier date: the
    /// date itself, muted; how long it has been carried lives in the tooltip/accessibility text.
    ///
    /// Round-3 fix: an empty `Group` (both `if`/`else if` branches false, no final `else`)
    /// rendered ZERO views, and a `Button`'s native label-sizing measured that as zero
    /// width even with `.frame(width:)` applied to the Group around it — the same class of
    /// "AppKit re-measures the label, ignoring the SwiftUI frame" bug already hit once with
    /// the priority glyph. `Color.clear.frame(width:height:)` is a REAL view with a REAL
    /// intrinsic size (matching `KMenuButton`'s own working pattern), so the label always
    /// has non-zero content to measure, not an absence for the button style to collapse.
    private var deadlineControl: some View {
        Button {
            showDeadlinePopover = true
        } label: {
            ZStack(alignment: .trailing) {
                Color.clear.frame(width: SlotWidth.deadline, height: 1)
                if let due = task.effectiveDue {
                    let shown = ListDueText.shown(due: due, original: task.originalDueDay, today: today)
                    // A dotted underline marks a date that comes from a subtask, not from this task.
                    // It shows on hover only: at rest it read as a link or an error on every row.
                    if shown.muted {
                        Text(shown.text)
                            .font(Typo.count)
                            .foregroundStyle(Tok.textTertiary)
                            .lineLimit(1)
                            .fixedSize()
                            .underline(isHovering && task.isDueDrivenBySubtask, pattern: .dot)
                            .opacity(task.status == .done ? 0.6 : 1)
                    } else {
                        KDeadlineLabel(text: shown.text, carryDays: 0, isDone: task.status == .done)
                            .underline(isHovering && task.isDueDrivenBySubtask, pattern: .dot)
                    }
                } else if isHovering {
                    Icon("calendar", size: Metrics.iconS).foregroundStyle(Tok.textDisabled)
                }
            }
        }
        .buttonStyle(.plain)
        .help(deadlineTooltip)
        .accessibilityLabel(deadlineTooltip)
        .popover(isPresented: $showDeadlinePopover) {
            ListDueField(current: task.dueDay) { setDue($0) }
        }
        .onReceive(NotificationCenter.default.publisher(for: ListRowRequests.pickDue)) { note in
            if ListRowRequests.taskID(note) == task.id { showDeadlinePopover = true }
        }
        // Closed by Esc or a click away: the keyboard goes back to the list, not to nothing.
        .onChange(of: showDeadlinePopover) { _, open in
            if !open { NotificationCenter.default.post(name: UIRequests.focusList, object: nil) }
        }
        // P: the shared type-ahead project picker, anchored on the row's date slot.
        .popover(isPresented: $showProjectPicker, arrowEdge: .bottom) {
            ListProjectPick(model: model, task: task) { showProjectPicker = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: ListRowRequests.pickProject)) { note in
            if ListRowRequests.taskID(note) == task.id, !task.isSubtask { showProjectPicker = true }
        }
        .onChange(of: showProjectPicker) { _, open in
            if !open { NotificationCenter.default.post(name: UIRequests.focusList, object: nil) }
        }
    }

    /// Full wording for hover tooltip and VoiceOver, since the visible label is calm/short.
    private var deadlineTooltip: String {
        guard let due = task.effectiveDue else { return String(localized: "list.filter.due.none") }
        let carry = KStatus.open.contains(task.status) ? max(0, today - due) : 0
        let dateText = ViewOptionsMapper.mediumDate(due)
        let dueText = task.isDueDrivenBySubtask
            ? String(format: String(localized: "list.row.tooltip.due.viasubtask"), dateText)
            : String(format: String(localized: "list.row.tooltip.due"), dateText)
        guard carry > 0 else { return dueText }
        let carried = KPlural.hr(carry, one: String(localized: "a11y.carry.count.one"), few: String(localized: "a11y.carry.count.few"), many: String(localized: "a11y.carry.count.many"))
        return "\(carried) · \(dueText)"
    }

    /// One write, one pill; picking the date the task already has changes nothing.
    private func setDue(_ day: Int?) {
        showDeadlinePopover = false
        guard task.dueDay != day else { return }
        model.store.setDue(task.id, day: day)
        model.commit(ListPills.due(day, title: task.title))
    }

    // MARK: - Subtasks (the child rows live in ChildTaskRow.swift)

    private var inlineAddSubtask: some View {
        SubtaskEntryRow(model: model, parentID: task.id, place: "list",
                        leadingInset: ChildRowGeometry.entryInset, glyphColumn: ChildRowGeometry.checkboxColumn)
    }

    /// "<title>, <project>, due <date>, <state>" (RowAccessibility.swift).
    private var accessibilityLabel: String {
        var due: String?
        if let effective = task.effectiveDue {
            let shownDay = ListDueKind.shownDay(due: effective, original: task.originalDueDay, today: today)
            due = String(format: String(localized: "a11y.row.due.value"), ViewOptionsMapper.mediumDate(shownDay))
        }
        return RowAccessibility.label(title: task.title, project: task.project?.name, due: due,
                                      state: ViewOptionsMapper.statusName(task.status))
    }

    /// What follows the label: priority, overdue, "due from a subtask", subtask progress.
    private var accessibilityValue: String {
        let progress = task.subtaskProgress
        let overdue = task.status != .done && (task.effectiveDue.map { $0 < today } ?? false)
        return RowAccessibility.value([
            task.priority == .none ? nil : ViewOptionsMapper.priorityName(task.priority),
            overdue ? String(localized: "a11y.row.overdue") : nil,
            task.isDueDrivenBySubtask ? String(localized: "a11y.row.due.viasubtask") : nil,
            progress.total > 0 ? String(format: String(localized: "a11y.row.subtasks.n_of_m"), progress.done, progress.total) : nil,
        ])
    }
}
