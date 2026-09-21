// Kronos/List/ListRowView.swift
// One task row: checkbox, title, fixed-order trailing slots (priority, effort, deadline,
// project glyph, subtask progress, recurrence), inline attribute editing, subtask
// disclosure, drag reorder (Manual sort only), context menu. Built on KListRow.
//
// Driver review round 2 (2026-09-19): trailing slots must occupy a FIXED width each so
// columns align down the list regardless of which attributes a given row has set; an
// unset attribute renders nothing by default and only reveals a faint hover affordance
// rather than a "None"/dash placeholder; priority shows its bars glyph only (name moves
// to tooltip + accessibilityLabel) and draws NOTHING at all for `.none`; overdue shows
// just the calm carry pill, not the words "Carried over" repeated on every row.
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
    @State private var showDeadlinePopover = false
    @State private var isHovering = false
    @State var isEditingTitle = false   // Title edit; not private — ListRowTitleEdit.swift needs it.
    @State var editedTitle = ""
    @FocusState var titleFieldFocused: Bool
    static var snapshotEditingTaskID: UUID?   // Snapshot-only trigger, set by ListSnapshots.

    private var isManualSort: Bool { ctx.options.sort == [.asc(.manual)] }
    private var today: Int { Day.today() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row.uiTestAnchor("row." + task.title)
            if subtasksExpanded {
                ForEach(task.orderedSubtasks, id: \.id) { sub in
                    subtaskRow(sub).uiTestAnchor("subrow." + sub.title)
                }
                inlineAddSubtask
            }
        }
        .onAppear { if task.id == ListRowView.snapshotEditingTaskID { beginTitleEdit() } }
    }

    private var row: some View {
        KListRow(isSelected: isSelected, isDone: task.status == .done, isChecked: task.status == .done,
                  accessibilityLabel: accessibilityLabel,
                  onToggle: { ListCompletion.toggle(task, store: model.store, model: model) },
                  onSelect: onSelect) {
            HStack(spacing: Space.x1) {
                if !task.orderedSubtasks.isEmpty {
                    Button {
                        withAnimation(Motion.curve(Motion.fast)) { subtasksExpanded.toggle() }
                    } label: {
                        Icon(subtasksExpanded ? "chevron-down" : "chevron-right", size: Metrics.iconXS)
                            .foregroundStyle(Tok.textTertiary)
                            .frame(minWidth: Metrics.minHit, minHeight: Metrics.minHit)
                            .contentShape(Rectangle())   // inside the label: the glyph alone is a 10 pt target
                    }
                    .buttonStyle(.plain)
                    .uiTestAnchor("arrow." + task.title)
                }
                titleView
            }
        } trailing: {
            trailingSlots
        }
        .if(isManualSort) { $0.draggable(task.id.uuidString) }
        .dropDestination(for: String.self) { items, _ in
            guard isManualSort, let raw = items.first, let draggedID = UUID(uuidString: raw), draggedID != task.id else { return false }
            reorderManual(draggedID, before: task.id)
            return true
        }
        .kContextLinkDrop(taskID: task.id, model: model)
        .contentShape(Rectangle())   // whole row answers a right click, selected or not
        .contextMenu { contextMenuContent }
        .followsExpandAll($subtasksExpanded, hasSubtasks: !task.orderedSubtasks.isEmpty)
        .onHover { isHovering = $0 }
        .animation(Motion.curve(Motion.fast), value: isHovering)
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
            if !task.orderedSubtasks.isEmpty {
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
                    model.store.setPriority(task.id, p)
                    model.didMutate()
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
        // `KPriority.none` draws nothing at rest — a faint hover-only affordance, matching
        // the deadline/effort slots, rather than four dim bars on every unprioritised row.
        // Swift trap (macos-1): `task.priority == .none` on a NON-OPTIONAL KPriority is the
        // enum case, not Optional.none — no unwrap needed, but the explicit `KPriority.none`
        // spelling below removes any doubt at the call site.
        .opacity(task.priority == KPriority.none && !isHovering ? 0 : 1)
    }

    /// Effort keeps its dots plus the short size code (XS…XL) when set — unlike priority,
    /// the size code is compact enough not to be the noise priority's full word was. Same
    /// glyph-outside-the-label fix as `priorityMenu` above. Unlike priority/deadline, an
    /// unset effort still draws its dim 5-dot placeholder at rest: those two slots hiding
    /// entirely at rest was already the design,
    /// but the effort column doing the same left an ~180px dead gap between the priority
    /// bars and the deadline on every row with no effort — the inspector and Capture
    /// (InspectorScreen.swift:238, CaptureReviewRow.swift:210) never hide it either.
    private var effortMenu: some View {
        Menu {
            ForEach(KEffort.allCases, id: \.self) { e in
                Button {
                    model.store.setEffort(task.id, e)
                    model.didMutate()
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
        }
        .frame(width: SlotWidth.effort, alignment: .trailing)
        .help(ViewOptionsMapper.effortName(task.effort))
    }

    /// No deadline: nothing shows at rest, a faint hairline hint appears on row hover so the
    /// slot stays discoverable/clickable without adding permanent noise. Overdue: ONLY the
    /// calm carry pill — the words "Carried over" are not repeated on every row, they move
    /// to the tooltip/accessibility text.
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
                if task.dueDay != nil {
                    KDeadlineLabel(text: deadlineText, carryDays: task.carryDays(today: today), isDone: task.status == .done)
                } else if isHovering {
                    Icon("calendar", size: Metrics.iconS).foregroundStyle(Tok.textDisabled)
                }
            }
        }
        .buttonStyle(.plain)
        .help(deadlineTooltip)
        .accessibilityLabel(deadlineTooltip)
        .popover(isPresented: $showDeadlinePopover) {
            deadlinePopover
        }
    }

    /// The relative label only — the day COUNT for an overdue task is the carry pill's job
    /// (`KDeadlineLabel`'s `carryDays`), so this never also renders "4d" for a task that
    /// pill already reads "4d" on: rendering both duplicated the same number twice. Overdue
    /// renders nothing here (the carry pill alone is the visible content). The slot was
    /// already fixed-width — dropping the one-day special case is what fixed a "Tomorrow"
    /// vs "3d" width mismatch.
    private var deadlineText: String {
        guard let due = task.dueDay else { return "" }
        let delta = due - today
        switch delta {
        case ..<0: return ""
        case 0: return String(localized: "list.filter.due.today")
        default: return "\(delta)d"
        }
    }

    /// Full wording for hover tooltip and VoiceOver, since the visible label is calm/short.
    private var deadlineTooltip: String {
        guard let due = task.dueDay else { return String(localized: "list.filter.due.none") }
        let carry = task.carryDays(today: today)
        let dateText = Day.iso(due)
        let dueText = String(format: String(localized: "list.row.tooltip.due"), dateText)
        guard carry > 0 else { return dueText }
        let carried = KPlural.hr(carry, one: String(localized: "a11y.carry.count.one"), few: String(localized: "a11y.carry.count.few"), many: String(localized: "a11y.carry.count.many"))
        return "\(carried) · \(dueText)"
    }

    private var deadlinePopover: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            Button(String(localized: "list.filter.due.today")) { setDue(today) }
            Button(String(localized: "deadline.quick.tomorrow")) { setDue(today + 1) }
            Button(String(localized: "deadline.quick.nextweek")) { setDue(today + 7) }
            Button(String(localized: "list.filter.due.none")) { setDue(nil) }
        }
        .buttonStyle(.plain)
        .font(Typo.row)
        .foregroundStyle(Tok.textPrimary)
        .padding(Space.x3)
        .background(Tok.overlay)
    }

    private func setDue(_ day: Int?) {
        model.store.setDue(task.id, day: day)
        model.didMutate()
        showDeadlinePopover = false
    }

    /// Manual drag reorder writes `sortIndex` directly via `update` (the only mutation
    /// `TaskStoring` exposes for a plain scalar field) using the same between-index
    /// arithmetic the protocol documents for `ordoIndex`: the mean of the two neighbours
    /// in the CURRENT manual order, so the moved row lands exactly before `beforeID`.
    private func reorderManual(_ draggedID: UUID, before beforeID: UUID) {
        let manualOrder = KTaskSorter.sorted(ctx.rows, by: [.asc(.manual)])
        guard let targetIndex = manualOrder.firstIndex(where: { $0.id == beforeID }) else { return }
        let before = targetIndex > 0 ? manualOrder[targetIndex - 1].sortIndex : nil
        let after = manualOrder[targetIndex].sortIndex
        let newIndex: Double
        if let before {
            newIndex = draggedID == manualOrder[targetIndex].id ? after : (before + after) / 2
        } else {
            newIndex = after - 1024
        }
        model.store.update(draggedID) { $0.sortIndex = newIndex }
        model.didMutate()
    }

    // MARK: - Subtasks

    private func subtaskRow(_ sub: KSubtask) -> some View {
        HStack(spacing: Space.x2) {
            KCheckbox(isChecked: sub.isDone, size: Metrics.listCheckboxSize) {
                model.store.toggleSubtask(sub.id)
                model.didMutate()
            }
            Text(sub.title)
                .font(Typo.meta)
                .foregroundStyle(sub.isDone ? Tok.textTertiary : Tok.textSecondary)
                .strikethrough(sub.isDone)
        }
        .padding(.leading, Metrics.listRowLeading + Metrics.listCheckboxSize + Metrics.listCheckboxTitleGap)
        .frame(height: Metrics.rowHeightDense)
    }

    @State private var newSubtaskTitle = ""

    private var inlineAddSubtask: some View {
        HStack(spacing: Space.x2) {
            Icon("plus", size: Metrics.iconS).foregroundStyle(Tok.textTertiary)
            TextField(String(localized: "detail.subtasks.add"), text: $newSubtaskTitle)
                .textFieldStyle(.plain)
                .font(Typo.meta)
                .foregroundStyle(Tok.textPrimary)
                .onSubmit {
                    let title = newSubtaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty else { return }
                    model.store.addSubtask(task.id, title: title)
                    model.didMutate()
                    newSubtaskTitle = ""
                }
        }
        .padding(.leading, Metrics.listRowLeading + Metrics.listCheckboxSize + Metrics.listCheckboxTitleGap)
        .frame(height: Metrics.rowHeightDense)
    }

    // MARK: - Context menu

    @ViewBuilder
    private var contextMenuContent: some View {
        Button(task.status == .done ? String(localized: "ctx.task.undone") : String(localized: "bar.menu.complete")) {
            ListCompletion.toggle(task, store: model.store, model: model)
        }
        Button(task.id == model.pinnedFocusTaskID ? String(localized: "ctx.task.unpinfocus") : String(localized: "ctx.task.focusthis")) {
            model.pinnedFocusTaskID = task.id == model.pinnedFocusTaskID ? nil : task.id
        }
        Button(String(localized: "ctx.task.breakdown")) {
            onSelect()
        }
        Menu(String(localized: "ctx.task.priority")) {
            ForEach(KPriority.allCases, id: \.self) { p in
                Button(ViewOptionsMapper.priorityName(p)) { model.store.setPriority(task.id, p); model.didMutate() }
            }
        }
        Menu(String(localized: "ctx.task.effort")) {
            ForEach(KEffort.allCases, id: \.self) { e in
                Button(ViewOptionsMapper.effortName(e)) { model.store.setEffort(task.id, e); model.didMutate() }
            }
        }
        Menu(String(localized: "ctx.task.move")) {
            Button(String(localized: "detail.noproject")) { model.store.move(task.id, toProject: nil); model.didMutate() }
            ForEach(model.store.allProjects(), id: \.id) { p in
                Button(p.name) { model.store.move(task.id, toProject: p); model.didMutate() }
            }
        }
        Divider()
        Button(String(localized: "ctx.task.delete")) {
            model.store.softDelete(task.id)
            model.didMutate()
            UndoToastCenter.shared.show(String(format: String(localized: "undo.deleted.name"), task.title))
        }
    }

    private var accessibilityLabel: String {
        var parts = [task.title]
        parts.append(ViewOptionsMapper.priorityName(task.priority))
        if let due = task.dueDay {
            parts.append(due <= today ? String(localized: "a11y.row.due.overdue")
                                       : String(format: String(localized: "a11y.row.due.value"), Day.iso(due)))
        }
        if let project = task.project { parts.append(project.name) }
        let progress = task.subtaskProgress
        if progress.total > 0 { parts.append(String(format: String(localized: "a11y.row.subtasks.n_of_m"), progress.done, progress.total)) }
        return parts.joined(separator: ", ")
    }
}

private extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition { transform(self) } else { self }
    }
}
