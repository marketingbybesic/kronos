// Kronos/List/ChildTaskRow.swift
// One child task in the middle list, under its parent row: the same marks a task row carries,
// compact and on ONE line at every text size (done circle, title, labels, link/notes
// indicators, due with the source marker, priority, effort, ⓘ). It is a full task, so every mark
// reads the child's own fields. Access points to its details: ⓘ, double-click anywhere but the title,
// Return on the focused row, the context menu: all call `AppModel.openDetails(taskID:)`. A
// double-click on the title renames it in place (ChildTaskRowTitleEdit.swift).
//
// Geometry: the child title starts one indent step right of its parent's title, and the row
// sits on the same rounded plate a task row uses, inset from the pane edge (ChildRowGeometry).
// The ⓘ button and the dotted due-source underline appear on hover (or focus/selection) only;
// at rest they were the loudest marks on the row.
import SwiftUI
import KronosCore

/// What a child's notes carry, read once per render: link lines and free text count separately.
struct ChildNotesSummary: Equatable {
    var hasLinks = false
    var hasText = false

    init(notes: String) {
        for raw in notes.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("link://") || line.hasPrefix("notes://") { hasLinks = true } else { hasText = true }
        }
    }
}

/// Where child rows and the add-subtask row sit, measured from the leading edge of the list's
/// row column (the same edge a task row's KListRow starts at).
enum ChildRowGeometry {
    /// KListRow pads its content this much on each side (KListRow.swift `rowContent` padding).
    static let listRowContentInset: CGFloat = 6
    /// The checkbox column: KCheckbox lays out at least `Metrics.minHit` wide around its circle.
    static var checkboxColumn: CGFloat { max(Metrics.listCheckboxSize, Metrics.minHit) }
    /// Title x of a top-level task row: KListRow inset + edge inset + checkbox column + gap, then the
    /// row's own fixed chevron gutter (`Metrics.minHit`) and its `Space.x1` gap (ListRowView).
    static var parentTitleX: CGFloat {
        listRowContentInset + Metrics.listRowLeading + checkboxColumn + Metrics.listCheckboxTitleGap
            + Metrics.minHit + Space.x1
    }
    /// A child title starts one indent step right of its parent's title.
    static var childTitleX: CGFloat { parentTitleX + Metrics.sidebarIndentStep }
    /// The child's plate is inset this much from the row column on both sides.
    static let plateInset = Metrics.sidebarOuterInset
    /// Leading padding inside the plate, so checkbox + gap end exactly at `childTitleX`.
    static var leadingInPlate: CGFloat {
        childTitleX - plateInset - checkboxColumn - Metrics.listCheckboxTitleGap
    }
    /// Leading inset of the add-subtask row (its "+" column is `checkboxColumn` wide): the "+" is
    /// centred on the child checkbox column and the text starts at the child title x.
    static var entryInset: CGFloat { childTitleX - checkboxColumn - Metrics.listCheckboxTitleGap }
}

struct ChildTaskRow: View {
    @Bindable var model: AppModel
    let child: KTask
    let parent: KTask
    let isDriver: Bool
    /// Carries a label of the list's label filter: marked like a due source (its parent row is
    /// listed because of it).
    var isLabelMatch: Bool = false
    let columnMode: ColumnMode
    var focus: FocusState<UUID?>.Binding
    let onSelectParent: () -> Void
    @State private var isHovering = false
    @State var isEditingTitle = false
    @State var editedTitle = ""
    @FocusState var titleFieldFocused: Bool
    @State private var titleMaxX: CGFloat = 0
    private static let rowSpace = "childRow"
    @Environment(\.chromaMode) private var chromaMode
    @Environment(\.kAccent) private var accent
    @Environment(\.colorSchemeContrast) private var contrast

    /// Tags shown before the rest collapse into "+N"; a longer label name is shortened.
    private static let visibleLabels = 1
    private static let labelMaxCharacters = 16

    /// A due source or a label-filter match: the reason the parent row is in this list.
    var isMarked: Bool { isDriver || isLabelMatch }
    private var isInspected: Bool { model.selectedTaskID == parent.id && model.inspectedSubtaskID == child.id }
    private var isFocused: Bool { focus.wrappedValue == child.id }
    /// The quiet marks (ⓘ, the source underline) show only while the row has attention.
    private var showsQuietMarks: Bool { isHovering || isFocused || isInspected }
    private var labels: [KLabel] { (child.labels ?? []).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
    private var notes: ChildNotesSummary { ChildNotesSummary(notes: child.notes) }

    var body: some View {
        HStack(spacing: Space.x2) {
            HStack(spacing: Metrics.listCheckboxTitleGap) {
                KCheckbox(isChecked: child.isDone, size: Metrics.listCheckboxSize, label: child.title) {
                    let wasDone = child.isDone
                    model.store.toggleSubtask(child.id)
                    let format = wasDone ? String(localized: "undo.uncompleted.name") : String(localized: "undo.completed.name")
                    model.commit(String(format: format, child.title))
                }
                titleView
            }
            .layoutPriority(1)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.rowSpace)).maxX } action: { titleMaxX = $0 }
            Spacer(minLength: Space.x2)
            if columnMode.showsProject, !labels.isEmpty {
                labelTags
                    .layoutPriority(2)   // the title truncates before a tag does
                    .uiTestAnchor("subrow.labels." + child.title)
            }
            indicators
            meta
                .layoutPriority(2)
            infoButton
                .layoutPriority(2)
        }
        .padding(.leading, ChildRowGeometry.leadingInPlate)
        .padding(.trailing, Space.x2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: Metrics.rowHeightDense)
        // The whole row is the hit shape BEFORE the click gestures below: without it the empty
        // span between title and marks (a Spacer over a clear background) took no clicks, so a
        // click or double-click there did nothing on an unmarked child.
        .contentShape(Rectangle())
        .background(plate)
        .padding(.horizontal, ChildRowGeometry.plateInset)
        .onHover { isHovering = $0 }
        .animation(Motion.hover, value: isHovering)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .subtaskFocusable(child.id, focus: focus, onSelectParent: onSelectParent)
        .coordinateSpace(name: Self.rowSpace)
        // Double-click: details, unless it lands on the checkbox or title (the title renames).
        // Simultaneous, so the single click still focuses the row and selects the parent; the
        // checkbox and ⓘ buttons keep their own clicks.
        .simultaneousGesture(SpatialTapGesture(count: 2, coordinateSpace: .named(Self.rowSpace)).onEnded { tap in
            if tap.location.x > titleMaxX { open() }
        })
        // Return on the focused row: details (the row is a focus stop, not a text field).
        .onKeyPress(.return) {
            guard focus.wrappedValue == child.id, !(NSApp.keyWindow?.firstResponder is NSTextView) else { return .ignored }
            open()
            return .handled
        }
        .onDrag { DragOut.provider(id: child.id, title: child.title, isChild: true, dossier: TaskDragText.render(TaskDragText.Input(task: child))) }
        .reportsDropRow(id: child.id, parentID: parent.id)
        .contentShape(Rectangle())
        .kSubtaskContextMenu(child, parent: parent, model: model, place: "subrow")
    }

    /// The same rounded plate a task row uses. The inspected child is SELECTED: the selection
    /// fill in its parent's project colour (a child inherits it) plus the selection hairline. A
    /// due source or label match keeps a quiet resting plate; hover and keyboard focus add the
    /// hover fill on top, so a marked row still answers the pointer.
    private var plate: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
        return shape
            .fill(restFill)
            .overlay(shape.fill(!isInspected && (isHovering || isFocused) ? Tok.hoverFill : Color.clear))
            .overlay(shape.strokeBorder(isInspected ? Tok.selectedEdge : Color.clear, lineWidth: Metrics.strokeHair))
    }

    private var restFill: Color {
        if isInspected {
            let hue = SelectionHue.forTask(child, neutral: chromaMode.isNeutralSelection).color(accent: accent)
            return KSelection.fill(hue, increasedContrast: contrast == .increased)
        }
        return isMarked ? Tok.hoverFill : Color.clear
    }

    private func open() { model.openDetails(taskID: child.id) }

    // MARK: Marks

    /// Passive label tags (KTag: no border, no hover). The full name stays in the help tag and
    /// in the accessibility label when the visible one is shortened.
    private var labelTags: some View {
        HStack(spacing: Space.x1) {
            ForEach(labels.prefix(Self.visibleLabels), id: \.id) { label in
                KTag(Self.shortName(label.name), dot: Color(hexString: label.colorHex))
                    .help(label.name)
            }
            if labels.count > Self.visibleLabels {
                Text("+\(labels.count - Self.visibleLabels)")
                    .font(Typo.count)
                    .foregroundStyle(Tok.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(labels.map(\.name).joined(separator: ", "))
    }

    static func shortName(_ name: String) -> String {
        guard name.count > labelMaxCharacters else { return name }
        return String(name.prefix(labelMaxCharacters - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    @ViewBuilder
    private var indicators: some View {
        if notes.hasLinks {
            Icon("link", size: Metrics.iconXS).foregroundStyle(Tok.textTertiary)
                .help(String(localized: "list.child.indicator.links"))
                .accessibilityLabel(String(localized: "list.child.indicator.links"))
                .uiTestAnchor("subrow.links." + child.title)
        }
        if notes.hasText {
            Icon("text.alignleft", size: Metrics.iconXS).foregroundStyle(Tok.textTertiary)
                .help(String(localized: "list.child.indicator.notes"))
                .accessibilityLabel(String(localized: "list.child.indicator.notes"))
                .uiTestAnchor("subrow.notes." + child.title)
        }
    }

    private var meta: some View {
        HStack(spacing: Space.x2) {
            if let day = child.dueDay {
                // A dotted underline marks the date that puts the parent in Today: the same sign
                // the parent's own date carries when a child drives it. Hover only.
                dueLabel(day)
                    .underline(isDriver && showsQuietMarks, pattern: .dot)
                    .opacity(child.isDone ? 0.6 : 1)
                    .help(isDriver ? String(format: String(localized: "list.row.tooltip.due.viasubtask"), ViewOptionsMapper.mediumDate(day))
                                   : ViewOptionsMapper.mediumDate(day))
                    .accessibilityHint(isDriver ? String(localized: "a11y.subtask.duedriver") : "")
                    .uiTestAnchor("subrow.due." + child.title)
            }
            if child.priority != .none {
                KPriorityIndicator(level: child.priority.rawValue, of: 4, label: ViewOptionsMapper.priorityName(child.priority), size: 12)
                    .uiTestAnchor("subtask.badge.priority")
            }
            if child.effort != .none {
                KEffortIndicator(level: child.effort.rawValue, of: 5, label: ViewOptionsMapper.effortName(child.effort), showLabel: false)
                    .uiTestAnchor("subrow.effort." + child.title)
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private func dueLabel(_ day: Int) -> some View {
        let shown = ListDueText.shown(due: day)
        if shown.muted {
            Text(shown.text)
                .font(Typo.count)
                .foregroundStyle(Tok.textTertiary)
                .lineLimit(1)
                .fixedSize()
        } else {
            KDeadlineLabel(text: shown.text, carryDays: 0, isDone: false)
        }
    }

    /// Always laid out and always clickable (a 24 pt target), drawn only while the row has
    /// attention.
    private var infoButton: some View {
        Button(action: open) {
            Icon("info", size: Metrics.iconS)
                .foregroundStyle(Tok.textTertiary)
                .opacity(showsQuietMarks ? 1 : 0)
                .frame(width: Metrics.minHit, height: Metrics.minHit)
                .contentShape(Rectangle())   // inside the label: the glyph alone is a tiny target
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "detail.subtask.open"))
        .help(String(localized: "detail.subtask.open"))
        .uiTestAnchor("list.subtask.info.\(child.id.uuidString)")
    }

    private var accessibilityLabel: String {
        var parts = [child.title, ViewOptionsMapper.priorityName(child.priority)]
        if let day = child.dueDay { parts.append(ViewOptionsMapper.mediumDate(day)) }
        if child.effort != .none { parts.append(ViewOptionsMapper.effortName(child.effort)) }
        parts.append(contentsOf: labels.map(\.name))
        if isLabelMatch { parts.append(String(localized: "a11y.subtask.labelmatch")) }
        return parts.joined(separator: ", ")
    }
}
