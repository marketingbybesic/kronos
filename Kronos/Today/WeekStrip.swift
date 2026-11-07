// Kronos/Today/WeekStrip.swift
// Plan v1.2 Phase 2, F3: seven days under the Today header, each the count of tasks planned for
// that day and the count due that day. Click a day to filter Today to it (the SAME `KFilter` the
// view-options popover already writes — Filtering.swift is the frozen contract surface, so this
// reuses `.custom` with a one-day `dueFrom...dueTo` range rather than adding a new `DueWindow`
// case). Drag a row from the list onto a day to plan it for that day. `⌥⌘W` collapses the strip.
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import KronosCore

struct WeekStrip: View {
    @Bindable var model: AppModel
    @State private var collapsed = UserDefaults.standard.bool(forKey: WeekStrip.collapsedKey)
    @State private var dropTarget: Int?
    @State private var hotkeyRevision = 0   // bumped on HotkeyRegistry.changed so ⌥⌘W picks up a live rebind

    private static let collapsedKey = "kronos.ui.weekstrip.collapsed"

    private var today: Int { Day.today() }
    private var buckets: [WeekDayBucket] {
        WeekBuckets.buckets(tasks: model.store.allTasks(), startDay: today)
    }

    var body: some View {
        let _ = hotkeyRevision   // re-read after a rebind, same rule FlowScreen's `model.version` read follows
        VStack(alignment: .leading, spacing: Space.x1) {
            header
            if !collapsed {
                HStack(spacing: Space.x2) {
                    ForEach(buckets, id: \.day) { bucket in
                        dayCell(bucket)
                    }
                }
            }
        }
        .padding(.horizontal, Space.x4)
        .padding(.top, Space.x3)
        .animation(Motion.curve(Motion.fast), value: collapsed)
        .uiTestAnchor("today.weekstrip")
    }

    private var header: some View {
        HStack(spacing: Space.x2) {
            Text(String(localized: "week.strip.title"))
                .font(Typo.sectionHdr)
                .foregroundStyle(Tok.textTertiary)
            Spacer(minLength: 0)
            Button(action: toggleCollapsed) {
                Icon(collapsed ? "chevron-down" : "chevron-up", size: Metrics.iconS)
            }
            .kButton(.icon)
            // Kronos v1.2 Phase 3 audit: registered as `today.weekstrip.collapse` in
            // HotkeyRegistry.swift for keymap-card coverage and Settings rebinding.
            .hotkey("today.weekstrip.collapse")
            .accessibilityLabel(String(localized: collapsed ? "week.strip.expand" : "week.strip.collapse"))
            .uiTestAnchor("today.weekstrip.toggle")
        }
    }

    private func toggleCollapsed() {
        collapsed.toggle()
        UserDefaults.standard.set(collapsed, forKey: Self.collapsedKey)
    }

    private func dayCell(_ bucket: WeekDayBucket) -> some View {
        let shownText = ListDueText.shown(due: bucket.day, today: today).text
        let isToday = bucket.day == today
        let isTargeted = dropTarget == bucket.day
        let help = cellHelp(bucket, shownText: shownText)
        return VStack(spacing: Space.x1) {
            Text(shownText)
                .font(isToday ? Typo.metaStrong : Typo.meta)
                .foregroundStyle(isToday ? Tok.textPrimary : Tok.textSecondary)
                .lineLimit(1)
            HStack(spacing: Space.x1) {
                if bucket.plannedCount > 0 {
                    Text("\(bucket.plannedCount)").font(Typo.count).foregroundStyle(Tok.textSecondary)
                }
                if bucket.dueCount > 0 {
                    Text("\(bucket.dueCount)").font(Typo.count).foregroundStyle(Tok.textTertiary)
                }
            }
            .frame(minHeight: Typo.size(11))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.x1)
        .background(isTargeted ? Tok.dropFill : (isToday ? Tok.hoverFill : Color.clear))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .strokeBorder(isTargeted ? Tok.borderActive : Color.clear, lineWidth: Metrics.ringWidth)
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { filterToday(day: bucket.day) }
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(help)
        .accessibilityAddTraits(.isButton)
        .animation(Motion.curve(Motion.fast), value: isTargeted)
        .onDrop(of: WeekDayDropDelegate.types, delegate: WeekDayDropDelegate(day: bucket.day, model: model, isTargeted: $dropTarget))
        .uiTestAnchor("week.day.\(bucket.day)")
    }

    private func cellHelp(_ bucket: WeekDayBucket, shownText: String) -> String {
        let planned = String(format: String(localized: "week.day.planned.a11y"), bucket.plannedCount)
        let due = String(format: String(localized: "week.day.due.a11y"), bucket.dueCount)
        return "\(shownText) — \(planned), \(due)"
    }

    /// Reuses the existing per-scope `ViewOptions.filter` (the same one the view-options popover
    /// writes), narrowed to one day via `.custom` + a one-day range — not a new parallel filter
    /// mechanism. Clearing it again uses the list's own existing "active rules" Reset chip.
    private func filterToday(day: Int) {
        var opts = model.viewOptions(for: .today)
        opts.filter.due = .custom
        opts.filter.dueFrom = day
        opts.filter.dueTo = day
        model.setOptions(opts, for: .today)
        model.didMutate()   // refresh-only: view filter state, not a store write
    }
}

/// One day cell's drop target: a task row dragged from the list onto a day plans it for that day.
struct WeekDayDropDelegate: DropDelegate {
    static let types: [UTType] = [.plainText]

    let day: Int
    let model: AppModel
    @Binding var isTargeted: Int?

    private var pasteboard: NSPasteboard { NSPasteboard(name: .drag) }

    private func draggedTaskID() -> UUID? {
        guard case .task(let id) = DropZonePayloadReader.read(pasteboard) else { return nil }
        return id
    }

    func validateDrop(info: DropInfo) -> Bool { draggedTaskID() != nil }

    func dropEntered(info: DropInfo) {
        if draggedTaskID() != nil { isTargeted = day }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: draggedTaskID() != nil ? .move : .forbidden)
    }

    func dropExited(info: DropInfo) {
        if isTargeted == day { isTargeted = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = nil
        guard let id = draggedTaskID(), let task = model.store.task(id), task.plannedDay != day else { return false }
        model.store.plan(id, day: day)
        let dayText = ListDueText.shown(due: day, today: Day.today()).text
        model.commit(String(format: String(localized: "week.pill.planned"), task.title, dayText))
        return true
    }
}
