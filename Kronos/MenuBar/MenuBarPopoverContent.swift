// Kronos/MenuBar/MenuBarPopoverContent.swift
// `PopoverContent` — split out of MenuBarOrdoController.swift purely to keep that file under
// the 500-line cap; no behaviour change, same struct.
import AppKit
import SwiftUI
import KronosCore

/// Posted by `MenuBarOrdoController.showPopover` when the meeting-capture hotkey fires
/// while the popover is ALREADY open — `focusCaptureOnAppear` only fires on first
/// presentation, so a second hotkey press while shown needs a live way to move focus.
extension Notification.Name {
    static let kronosMenuBarFocusCaptureField = Notification.Name("kronosMenuBarFocusCaptureField")
}

/// The popover's content view: reads `model.pinnedFocusTaskID` / `model.ordoFocus` /
/// `model.version` / `model.coach` directly (an `@Observable` read, so it re-renders on any
/// of them changing) rather than trusting a snapshot handed in at construction — the
/// NSHostingController that hosts this is built once per popover presentation. Injects
/// `.environment(\.chromaMode,…)` / `.environment(\.kAccent,…)` itself every render since
/// this view's AppKit root does not inherit the shell's environment (same pattern as
/// `AppShellView`'s root — see Accent.swift).
struct PopoverContent: View {
    let model: AppModel
    var focusCaptureOnAppear: Bool = false
    /// Snapshot-only override for the BLOCK section (nil in the real app). `model.coach`'s
    /// block state only ever populates from a live `EventKitCalendar` via
    /// `refreshBlocks()` (AppDelegate on launch/wake/minute, and this view's own
    /// `.onAppear` for a popover opened later) — there is no injection seam onto
    /// `CoachModel` (its `blockSuggestion`/`todaysBlocks` are `private(set)`, and
    /// `AppModel` always constructs it with the real calendar), so the
    /// `menubar.popover.block` snapshot renders this fixed value instead of depending on
    /// the machine's actual calendar/consent state. This is a wiring gap to close later.
    var previewBlockSuggestion: BlockSuggestion?? = nil
    @State private var justCompleted: (taskID: UUID, wasSubtask: Bool)?
    @State private var skippedThisSession: Set<UUID> = []
    @State private var captureText = ""
    @FocusState private var focusedField: MenuBarFocusField?
    /// The event currently offered for linking — set by the strip's per-chip "Link" action
    /// (item 3), or defaults to the current-or-next unmatched block so the main banner
    /// shows a picker even before anything is tapped in the strip.
    @State private var linkingEvent: KCalendarEvent?

    private var isPinned: Bool { model.pinnedFocusTaskID != nil }

    /// Same reader `MenuBarOrdoController` uses for the bar's own bitmap (`TimeBlocksModel.
    /// blockFocusTaskID`, Kronos/TimeBlocks/TimeBlocksModel.swift) — the view and the bar must
    /// never disagree about the current block. Recomputed each render (cheap: no I/O, reads
    /// state `CoachModel.refreshBlocks()` already published) rather than cached in `@State`,
    /// same pattern this view already uses for `resolved`/`nextRows` reading `model` live.
    private var blockTasks: TimeBlocksModel { TimeBlocksModel(model: model) }

    private var resolved: (id: UUID, title: String, firstMove: String?, remaining: Int, project: KProject?)? {
        let _ = model.version
        if let blockID = blockTasks.blockFocusTaskID, let task = model.store.task(blockID) {
            return (task.id, task.title, task.firstMove, model.ordoFocus.remaining, task.project)
        }
        if let pinID = model.pinnedFocusTaskID, let task = model.store.task(pinID) {
            return (task.id, task.title, task.firstMove, model.ordoFocus.remaining, task.project)
        }
        let focus = model.ordoFocus
        guard let id = focus.taskID else { return nil }
        let project = model.store.task(id)?.project
        return (id, focus.title, focus.firstMove, focus.remaining, project)
    }

    /// Block precedence also lists the block's tasks first in the popover, not just the top
    /// focus row — `MenuBarBlockFocus.reordered` (hand-tested) puts them ahead of the normal
    /// open-list order, focus row excluded either way.
    private var nextRows: [KTask] {
        let rows = MenuBarNextRows.rows(model: model, scope: model.scope, focusTaskID: resolved?.id, excluding: skippedThisSession)
        guard blockTasks.blockFocusTaskID != nil else { return rows }
        let orderedIDs = MenuBarBlockFocus.reordered(listIDs: rows.map(\.id), blockTaskIDs: blockTasks.focusTaskIDs, focusID: resolved?.id)
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        // Block tasks may include ones outside `rows`' own scope/filter (a linked task from
        // another project, say) — resolve those straight from the store so they still show.
        return orderedIDs.compactMap { byID[$0] ?? model.store.task($0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.x3) {
                blockSection
                KOrdoPopoverG(task: resolved, isPinned: isPinned, onComplete: complete, onUnpin: unpin,
                              onNotNow: resolved != nil ? notNow : nil, onSnooze: resolved != nil ? snooze : nil)
                if let justCompleted {
                    KUndoPill(message: String(format: String(localized: "undo.completed.name"),
                                              model.store.task(justCompleted.taskID)?.title ?? ""),
                              onUndo: { undo(justCompleted) },
                              onExpire: { self.justCompleted = nil })
                }
                MenuBarNextSection(rows: nextRows, onSelect: pin)
                MenuBarPresetRow(presets: model.coach.presets, activeID: model.coach.activePreset(for: model.scope).id,
                                  onSelect: { model.coach.applyPreset($0, to: model.scope) })
                MenuBarEnergyRow(energy: Binding(get: { ImpulsEnergyMemory.todayEnergy() ?? .mid },
                                                  set: { ImpulsEnergyMemory.rememberToday($0) }))
                KHairline()
                MenuBarCaptureField(text: $captureText, isFocused: $focusedField, onFindTasks: findTasks)
                KHairline()
                footerRow
            }
            .padding(Space.x4)
        }
        .frame(width: 380)
        // OLED: the popover's own corners must read as true black (gate-shots' corner
        // check), not the slightly-raised `Tok.overlay` other popovers use for a floating
        // sheet look — this one fills edge-to-edge under the status item instead.
        .background(Tok.bg)
        .environment(\.chromaMode, model.chromaMode)
        .environment(\.kAccent, Accent.resolve(model.coach.settings.accentHex, mode: model.chromaMode))
        .accessibilityElement(children: .contain)
        .onAppear {
            // Never touches EventKit when a snapshot fixture is supplied: no real calendar
            // access, no consent prompt, ever, from an automated run.
            if previewBlockSuggestion == nil { Task { await model.coach.refreshBlocks() } }
            if focusCaptureOnAppear { focusedField = .capture }
        }
        .onReceive(NotificationCenter.default.publisher(for: .kronosMenuBarFocusCaptureField)) { _ in
            focusedField = .capture
        }
        // Esc-closes is `NSPopover`'s own default behaviour for `.transient` (no custom
        // `.onKeyPress(.escape)` here — this file is not on `verify-hotkeys.mjs`'s
        // ALLOW_LIST, and adding an unlisted key literal fails that gate outright).
    }

    /// nil override means "read the live coach"; a non-nil override (snapshot only) is
    /// used exactly as given, including `.some(nil)` meaning "no suggestion, force the
    /// section to render nothing" — see `previewBlockSuggestion`'s own doc comment.
    private var blockSuggestion: BlockSuggestion? {
        if let previewBlockSuggestion { return previewBlockSuggestion }
        return model.coach.blockSuggestion
    }

    /// The unmatched block that is current or starts next (team-lead spec, item 3):
    /// `event.start <= now + lead` (the same lead the block coach itself uses) and
    /// `event.end > now`. `linkingEvent` (set by the strip's per-chip Link action) wins
    /// when present so tapping a LATER unmatched chip's Link still opens that one.
    private var defaultUnmatchedEvent: KCalendarEvent? {
        guard previewBlockSuggestion == nil else { return nil }
        let now = Date()
        let lead = TimeInterval(max(0, model.coach.settings.blockLeadMinutes) * 60)
        return model.coach.todaysBlocks
            .filter { $0.projectID == nil && $0.event.start <= now.addingTimeInterval(lead) && $0.event.end > now }
            .min { $0.event.start < $1.event.start }?.event
    }

    private var unmatchedEvent: KCalendarEvent? { linkingEvent ?? defaultUnmatchedEvent }

    @ViewBuilder
    private var blockSection: some View {
        if previewBlockSuggestion == nil, model.coach.calendarAccess != .granted, model.coach.settings.blockCoachEnabled {
            MenuBarCalendarAccessRow()
        } else if let suggestion = blockSuggestion {
            MenuBarBlockBanner(suggestion: suggestion, unmatchedEventTitle: nil, projects: model.store.allProjects(),
                                onSwitch: { model.coach.switchToBlock() }, onStay: { model.coach.stayInCurrent() },
                                onLink: { _ in })
        } else if let event = unmatchedEvent {
            MenuBarBlockBanner(suggestion: nil, unmatchedEventTitle: event.title, projects: model.store.allProjects(),
                                onSwitch: {}, onStay: {}, onLink: { project in link(event, to: project) })
        }
        if previewBlockSuggestion == nil {
            MenuBarTodaysBlocksStrip(blocks: model.coach.todaysBlocks, projectName: projectName,
                                      onLinkEvent: { linkingEvent = $0 })
        }
    }

    private var footerRow: some View {
        HStack(spacing: Space.x4) {
            Button(String(localized: "menubar.footer.quickadd"), action: openQuickAdd)
                .buttonStyle(.plain).font(Typo.meta).foregroundStyle(Tok.textSecondary).fixedSize()
            Button(String(localized: "menubar.footer.open"), action: openKronosWindow)
                .buttonStyle(.plain).font(Typo.meta).foregroundStyle(Tok.textSecondary).fixedSize()
            Button(String(localized: "menubar.footer.settings"), action: openSettings)
                .buttonStyle(.plain).font(Typo.meta).foregroundStyle(Tok.textSecondary).fixedSize()
            Spacer(minLength: 0)
            KChromaModeSwitch(mode: Binding(get: { model.chromaMode }, set: { model.chromaMode = $0 }))
        }
    }

    private func projectName(_ id: UUID) -> String? { model.store.allProjects().first { $0.id == id }?.name }

    private func complete() {
        guard let id = resolved?.id, let task = model.store.task(id) else { return }
        if let next = task.nextOpenSubtask {
            model.store.toggleSubtask(next.id)
            model.didMutate()
            justCompleted = (id, true)
        } else {
            model.store.complete(id)
            if model.pinnedFocusTaskID == id { model.pinnedFocusTaskID = nil }
            model.didMutate()
            justCompleted = (id, false)
        }
        // Shell-level pill too (KUndoPill.swift), alongside this popover's own inline one —
        // the popover is a separate window from the main shell, so the shell needs its own post.
        UndoToastCenter.shared.show(String(format: String(localized: "undo.completed.name"), task.title))
        NotificationCenter.default.post(name: .kronosDidCompleteFromBar, object: nil)
    }

    private func unpin() {
        model.pinnedFocusTaskID = nil
    }

    /// Skip to the next task WITHOUT completing and without shame copy — a session-local
    /// set, never a store write: pinning the next row is enough to move on, and the skipped
    /// task simply reappears next time the popover opens fresh.
    private func notNow() {
        guard let id = resolved?.id else { return }
        skippedThisSession.insert(id)
        if let next = nextRows.first(where: { $0.id != id }) ?? nextRows.first {
            model.pinnedFocusTaskID = next.id
        } else if model.pinnedFocusTaskID == id {
            model.pinnedFocusTaskID = nil
        }
    }

    private func snooze() {
        guard let id = resolved?.id else { return }
        model.store.snooze(id)
        if model.pinnedFocusTaskID == id { model.pinnedFocusTaskID = nil }
        model.didMutate()
    }

    private func pin(_ task: KTask) {
        model.pinnedFocusTaskID = task.id
    }

    /// Teaches the link (item 3): `CoachModel.link` matches this exact event title forever
    /// after. Clears `linkingEvent` so the strip/banner fall back to the next
    /// current-or-next unmatched block, if any, once `refreshBlocks()` runs again.
    private func link(_ event: KCalendarEvent, to project: KProject) {
        model.coach.link(eventTitle: event.title, to: project.id)
        linkingEvent = nil
    }

    private func undo(_ completed: (taskID: UUID, wasSubtask: Bool)) {
        model.store.undo()
        model.didMutate()
        justCompleted = nil
    }

    private func findTasks() {
        requestCapturePrefill(model: model, text: captureText)
        captureText = ""
    }

    private func openQuickAdd() { AppDelegate.shared?.quickAdd.toggle() }

    private func openKronosWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.isVisible == false { window.makeKeyAndOrderFront(nil) }
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }

    /// Same notification the sidebar's own settings button posts (`Kronos/Palette/PaletteNotifications.swift`,
    /// observed by `AppShellView`) — the app already has one mechanism for opening the
    /// Settings scene from outside the window; this reuses it rather than calling the
    /// private `showSettingsWindow:` selector a second time from a different file.
    /// `AppShellView` (the observer) only exists once the main window has been created at
    /// least once, so this brings a window forward first exactly like "Open Kronos" above.
    private func openSettings() {
        openKronosWindow()
        NotificationCenter.default.post(name: .kronosSettingsRequested, object: nil)
    }
}
