// Kronos/TimeBlocks/TimeBlocksScreen.swift
//
// Header: ‹ arrow, block title + time range, › arrow, flanking the title on both sides.
// Below it: the tasks linked to that block (direct task link, or the block's own matched
// project). Left/Right keys mirror the arrow buttons. When the current block's end time
// passes while this screen is open, a calm in-view prompt offers "switch to <next>" or
// "stay" (Return = switch, matching every other modal card's Return-accepts convention).
import SwiftUI
import KronosCore

struct TimeBlocksScreen: View {
    let model: AppModel
    /// Snapshot-only override, same seam `CoachBanner.previewSuggestion` uses and for the same
    /// reason: `CoachModel`'s calendar provider is fixed inside `AppModel` (Kronos/Shared/**),
    /// so a harness process has no real calendar to seed `model.coach.todaysBlocks` from. The
    /// real screen always calls `TimeBlocksScreen(model:)`; only `TimeBlocksSnapshots` supplies
    /// this. Same wiring gap `CoachBanner` also has: an injectable calendar in
    /// `AppModel.init` removes both.
    var previewBlocks: [TimeBlockEntry]?
    /// Snapshot-only: freezes "now" so the ended-prompt and current-block math are deterministic
    /// in a gate shot instead of racing the real clock.
    var previewNow: Date?

    @State private var blocksModel: TimeBlocksModel?
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            Tok.bg
            if let blocksModel {
                content(blocksModel)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusable(true)
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear {
            isFocused = true
            let m = TimeBlocksModel(model: model)
            if let previewBlocks { m.setPreview(blocks: previewBlocks, now: previewNow ?? Date()) }
            blocksModel = m
        }
        .onChange(of: model.version) { _, _ in blocksModel?.reload(now: previewNow ?? Date()) }
        .onKeyPress(.leftArrow) { blocksModel?.goPrevious(); return .handled }
        .onKeyPress(.rightArrow) { blocksModel?.goNext(); return .handled }
        .onKeyPress(.return) {
            guard let blocksModel, blocksModel.showsEndedPrompt else { return .ignored }
            blocksModel.switchToNext()
            return .handled
        }
    }

    @ViewBuilder
    private func content(_ blocksModel: TimeBlocksModel) -> some View {
        VStack(spacing: 0) {
            header(blocksModel)
            if blocksModel.blocks.count > 1 {
                dayStrip(blocksModel)
            }
            if let entry = blocksModel.current {
                if blocksModel.showsEndedPrompt {
                    endedPrompt(blocksModel, ended: entry)
                }
                let tasks = blocksModel.tasks(for: entry)
                if tasks.isEmpty {
                    emptyState
                } else {
                    taskList(tasks)
                }
            } else {
                emptyState
            }
        }
        .padding(.top, Space.x5)
    }

    // MARK: Day strip — the whole day's blocks at a glance, current one highlighted. Only
    // shown with more than one block (a single-block day has nothing to compare it against).

    private func dayStrip(_ blocksModel: TimeBlocksModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.x2) {
                ForEach(Array(blocksModel.blocks.enumerated()), id: \.element.id) { index, entry in
                    dayStripChip(entry, isCurrent: index == blocksModel.currentIndex) {
                        blocksModel.jump(to: index)
                    }
                }
            }
            .padding(.horizontal, Space.x6)
        }
        .padding(.bottom, Space.x4)
    }

    private func dayStripChip(_ entry: TimeBlockEntry, isCurrent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Space.x1) {
                Text(entry.event.title)
                    .font(Typo.metaStrong)
                    .foregroundStyle(isCurrent ? Tok.textPrimary : Tok.textSecondary)
                    .lineLimit(1)
                Text(Self.timeFormatter.string(from: entry.event.start))
                    .font(Typo.count)
                    .foregroundStyle(Tok.textTertiary)
            }
            .padding(.horizontal, Space.x3)
            .padding(.vertical, Space.x2)
            .frame(minWidth: 96, alignment: .leading)
            .background(isCurrent ? Tok.controlFill : Color.clear)
            .kBorder(isCurrent ? Tok.borderActive : Tok.borderControl, radius: Radius.control)
            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .uiTestAnchor("timeblocks.daystrip." + entry.event.title)
    }

    // MARK: Header — ‹ block title + range › (arrows either side of the title)

    private func header(_ blocksModel: TimeBlocksModel) -> some View {
        HStack(spacing: Space.x3) {
            arrowButton("chevron-left", enabled: blocksModel.canGoPrevious, id: "timeblocks.prev") {
                blocksModel.goPrevious()
            }
            Spacer(minLength: 0)
            VStack(spacing: Space.x1) {
                Text(blocksModel.current?.event.title ?? String(localized: "timeblocks.title"))
                    .font(Typo.title)
                    .tracking(Tracking.tight)
                    .foregroundStyle(Tok.textPrimary)
                    .lineLimit(1)
                if let entry = blocksModel.current {
                    Text(rangeText(entry))
                        .font(Typo.count)
                        .foregroundStyle(Tok.textTertiary)
                }
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
            arrowButton("chevron-right", enabled: blocksModel.canGoNext, id: "timeblocks.next") {
                blocksModel.goNext()
            }
        }
        .padding(.horizontal, Space.x6)
        .padding(.bottom, Space.x4)
    }

    private func arrowButton(_ icon: String, enabled: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Icon(icon, size: Metrics.iconM)
                .foregroundStyle(enabled ? Tok.textSecondary : Tok.textDisabled)
                .frame(minWidth: Metrics.minHit, minHeight: Metrics.minHit)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .uiTestAnchor(id)
    }

    private func rangeText(_ entry: TimeBlockEntry) -> String {
        "\(Self.timeFormatter.string(from: entry.event.start))–\(Self.timeFormatter.string(from: entry.event.end))"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = KronosLocale.calendar
        f.locale = KronosLocale.current
        f.setLocalizedDateFormatFromTemplate("Hm")
        return f
    }()

    // MARK: End-of-block prompt

    private func endedPrompt(_ blocksModel: TimeBlocksModel, ended: TimeBlockEntry) -> some View {
        HStack(spacing: Space.x3) {
            Icon("calendar", size: Metrics.iconS).foregroundStyle(Tok.textTertiary)
            Text(promptText(blocksModel))
                .font(Typo.row)
                .foregroundStyle(Tok.textSecondary)
                .lineLimit(1)
            Spacer(minLength: Space.x3)
            Button(String(localized: "coach.block.stay")) { blocksModel.stay() }
                .kButton(.ghost, size: .compact)
            Button(String(localized: "coach.block.switch")) { blocksModel.switchToNext() }
                .kButton(.secondary, size: .compact)
                .disabled(blocksModel.next == nil)
        }
        .padding(.horizontal, Space.x3)
        .frame(height: Metrics.controlRegular)
        .kBorder(Tok.borderControl, radius: Radius.control)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .padding(.horizontal, Space.x6)
        .padding(.bottom, Space.x3)
        .uiTestAnchor("timeblocks.endedprompt")
    }

    private func promptText(_ blocksModel: TimeBlocksModel) -> String {
        if let next = blocksModel.next {
            return String(format: String(localized: "timeblocks.ended.prompt"), next.event.title)
        }
        return String(localized: "timeblocks.ended.prompt.nonext")
    }

    // MARK: Task list — a compact row of its own (ListRowView needs ListContext/undo binding/
    // columnMode from Kronos/List/**, outside this leaf's OWNS; the brief allows a leaf-owned
    // row when reuse would require editing/depending on that file).

    private func taskList(_ tasks: [KTask]) -> some View {
        ScrollView {
            KPanel {
                VStack(spacing: 0) {
                    ForEach(tasks, id: \.id) { task in
                        TimeBlockTaskRow(task: task, model: model)
                            .uiTestAnchor("timeblocks.row." + task.title)
                        if task.id != tasks.last?.id { KHairline() }
                    }
                }
            }
            .padding(.horizontal, Space.x6)
        }
    }

    private var emptyState: some View {
        KEmptyState(icon: "calendar", title: String(localized: "timeblocks.empty.title"),
                   message: String(localized: "timeblocks.empty.hint"))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .uiTestAnchor("timeblocks.empty")
    }
}

/// One task row: checkbox, title, project glyph, deadline — the trailing attributes a block
/// view needs to recognise a task at a glance, without the full trailing-slot machinery
/// `ListRowView` builds for the main list (priority/effort menus, subtasks, drag reorder,
/// context menu — none of it is this screen's job; it links tasks to blocks, it does not
/// replace the list for editing them).
private struct TimeBlockTaskRow: View {
    let task: KTask
    let model: AppModel
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Space.x2) {
            KCheckbox(isChecked: task.status == .done, size: Metrics.listCheckboxSize) {
                if task.status == .done { model.store.reopen(task.id) } else { model.store.complete(task.id) }
                model.didMutate()
            }
            VStack(alignment: .leading, spacing: Space.x1) {
                Text(task.title)
                    .font(Typo.row)
                    .foregroundStyle(task.status == .done ? Tok.textTertiary : Tok.textPrimary)
                    .strikethrough(task.status == .done)
                    .lineLimit(1)
                    .truncationMode(.tail)
                // Quiet meta line (art-direction: "give rows an ... inline project name" so the
                // list carries information, not air) — only when there is something to say.
                if let project = task.project {
                    Text(project.name)
                        .font(Typo.meta)
                        .foregroundStyle(Tok.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Space.x2)
            if let project = task.project {
                KProjectGlyph(icon: project.icon, colorHex: project.colorHex, size: Metrics.iconM, carrier: .other)
            }
        }
        .padding(.horizontal, Space.x2)
        .padding(.vertical, Space.x2)
        .contentShape(Rectangle())
        .background(isHovering ? Tok.hoverFill : Color.clear)
        .onHover { isHovering = $0 }
        .animation(Motion.hover, value: isHovering)
    }
}
