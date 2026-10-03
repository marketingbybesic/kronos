// Kronos/MenuBar/MenuBarOrdoController.swift
// Owns the NSStatusItem showing THE focus task: `model.focusTaskID` — the pinned task if
// any, else the automatic first row of the open list (`model.ordoFocus`). Style G popover:
// first move as hero, title under it, project glyph + name, one complete control, 5 s undo,
// remaining count quiet. Completion ticks the next open subtask before completing the task
// (spec §5.1 Bar-check rule, carried over to the menu bar verbatim). The popover widens into
// the full cockpit — see `PopoverContent` below and the sibling MenuBar*.swift files it
// composes.
//
// Clicking the CIRCLE glyph completes the focus task right from the bar (its next open
// subtask first, same as the popover's own Complete control — spec §5.1 Bar-check rule);
// clicking anywhere else in the item toggles the popover. The status item's image is one
// flattened bitmap (glyph + title baked together by `makeLabelImage`), so there is no
// separate AppKit subview to hang a click target on — `circleWidth` below is measured from
// the SAME SwiftUI layout pass that renders that bitmap, and
// `MenuBarHitRegion.region(forX:circleWidth:)` (pure, self-tested) decides which zone a
// click's local x falls into.

import AppKit
import SwiftUI
import KronosCore
import KronosSnapshot

@MainActor
final class MenuBarOrdoController: NSObject, NSPopoverDelegate {
    let model: AppModel

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    /// The rendered circle glyph's width in the button's own point space, refreshed by
    /// every `render()` — the hit test in `clicked(_:)` compares a click's local x against
    /// this, not a hard-coded constant, since the glyph never changes size but this keeps
    /// the two paths (draw vs. hit-test) reading the same source of truth.
    private var circleWidth: CGFloat = 0

    /// Settings > Appearance's menu-bar title width (item 4, feature I — a raw character
    /// COUNT, unrelated to MenuBarPrefs.MenuBarWidth's Compact/Medium/Wide/Full CASES set
    /// in this leaf's own Settings > Ordo section below). 0 = not set = the default below.
    /// A plain UserDefaults key, not `AppModel` state — Settings writes it directly and
    /// this controller only reads it, same pattern as every other cross-feature default in
    /// this app (`ImpulsEnergyMemory`, `HotkeyRegistry` overrides).
    /// The quiet boundary lines (time left in a block, ...): one clock, ticked every 60 s.
    let quiet = MenuBarQuiet()
    private var minuteTimer: Timer?

    init(model: AppModel) { self.model = model }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.target = self
        item.button?.action = #selector(clicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        quiet.tick(model: model)
        // A minute tick: the bar's time-left suffix and the popover's quiet line follow the clock
        // even when nothing else changes (hyperfocus is exactly the "nothing changes" case).
        minuteTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.minuteTick() }
        }
        render()
        // "To the camera" needs the item's on-screen frame, which exists only after this returns.
        DispatchQueue.main.async { [weak self] in self?.render() }

        NotificationCenter.default.addObserver(self, selector: #selector(focusChanged),
                                                name: .kronosOrdoFocusDidChange, object: nil)
        // Global hotkeys (Kronos/QuickAdd/QuickAddController.swift, HotkeyRegistry ids
        // "global.meetingcapture" / "global.showordo") only POST these — this controller
        // is the one that acts on them, per the brief: show the popover for both, and for
        // meeting capture also focus the capture field.
        NotificationCenter.default.addObserver(self, selector: #selector(meetingCaptureRequested),
                                                name: .kronosMeetingCaptureRequested, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(showOrdoRequested),
                                                name: .kronosShowOrdoRequested, object: nil)
        // Settings > Ordo writes `MenuBarPrefs` directly to UserDefaults.standard
        // (no AppModel round trip) — observe the domain so a live width change re-renders
        // immediately, per item 4 ("re-applied when UserDefaults changes").
        NotificationCenter.default.addObserver(self, selector: #selector(focusChanged),
                                                name: UserDefaults.didChangeNotification, object: nil)
    }

    /// A selector observer runs on whatever thread posted. `UserDefaults.didChangeNotification` is
    /// posted on the WRITING thread, and a background AI call writes a has-key flag: rendering
    /// from there read SwiftData off the main thread and took the whole app down (segfault while
    /// tasks were being created over MCP). Always render on main.
    @objc private func focusChanged() {
        if Thread.isMainThread { render() } else { DispatchQueue.main.async { [weak self] in self?.render() } }
    }

    @objc private func meetingCaptureRequested() {
        showPopover(focusCapture: true)
    }

    @objc private func showOrdoRequested() {
        showPopover(focusCapture: false)
    }

    /// The task the bar shows right now: the current time block's own first open task when
    /// block precedence applies (MenuBarBlockFocus.swift, hand-tested), else the pin (loaded
    /// fresh from the store so a renamed title/first move/project stays live), else the
    /// automatic Ordo focus. `subtask` is that task's next OPEN subtask title, if any — what
    /// "Menu bar shows" composes with the task title per the Settings > Ordo choice.
    private func resolvedFocus() -> (id: UUID, title: String, firstMove: String?, subtask: String?)? {
        guard let id = Self.focusTaskID(model: model) else { return nil }
        guard let task = model.store.task(id) else {
            let focus = model.ordoFocus
            return (id, focus.title, focus.firstMove, nil)
        }
        return (task.id, task.title, FirstMoveLogic.moveText(for: task), task.nextOpenSubtask?.title)
    }

    /// The bar's task, ordered by the same `SnapshotHead.resolve` the Snapshot uses (time block, then
    /// the pin, then the first eligible row of the shown list), so the bar and the Snapshot name one
    /// task. The pin and the list head come from the shared `nextFromShownList` pick; the fallbacks
    /// are the popover's (`MenuBarFocusResolver`): a mounted list with no eligible row means nothing is
    /// next, no list on screen means the Today head.
    static func focusTaskID(model: AppModel) -> UUID? {
        let blockFocus = TimeBlocksModel(model: model).blockFocusTaskID.flatMap { model.store.task($0) != nil ? $0 : nil }
        let picked = model.nextFromShownList
        let pin = picked.flatMap { $0.id == model.pinnedFocusTaskID ? $0.id : nil }
        if let head = SnapshotHead.resolve(blockFocus: blockFocus, pin: pin, shownHead: picked?.id) { return head.taskID }
        if !model.shownListHead.ids.isEmpty { return nil }
        return NextFallback.todayHead(store: model.store, today: Day.today(calendar: KronosLocale.calendar), limit: 1).first
    }

    private func minuteTick() {
        quiet.tick(model: model)
        render()
    }

    private func render() {
        guard let button = statusItem?.button else { return }
        guard let focus = resolvedFocus() else {
            let (image, width) = allClearImage()
            button.image = image
            button.image?.isTemplate = true
            circleWidth = width
            button.toolTip = String(localized: "bar.empty")
            button.setAccessibilityLabel("Kronos — " + String(localized: "menubar.allclear"))
            return
        }
        let (image, width) = fittedLabelImage(task: focus.firstMove ?? focus.title, subtask: focus.subtask, suffix: quiet.barSuffix ?? "")
        button.image = image
        button.image?.isTemplate = true
        circleWidth = width
        button.toolTip = focus.title
        button.setAccessibilityLabel("Kronos — " + focus.title)
    }

    /// How wide the whole item may be. "To the camera": from this item's right edge to the right
    /// side of the camera housing (or to the middle of a screen without one). That is only free
    /// space while Kronos is the LEFTMOST status item; Settings says how to put it there.
    private func availablePoints() -> CGFloat {
        guard MenuBarPrefs.fillToCamera,
              let window = statusItem?.button?.window, window.frame.width > 0,
              let screen = window.screen ?? NSScreen.main else { return CGFloat(MenuBarPrefs.maxPoints) }
        let leftLimit = screen.auxiliaryTopRightArea?.minX ?? screen.frame.midX
        return max(CGFloat(MenuBarPrefs.pointsRange.lowerBound), window.frame.maxX - leftLimit - Space.x4)
    }

    /// Largest title that fits `availablePoints()`, found on the REAL rendered image (a character
    /// count cannot know how wide "W" is against "i"). Binary search: at most 8 renders.
    private func fittedLabelImage(task: String, subtask: String?, suffix: String = "") -> (NSImage, CGFloat) {
        let limit = availablePoints()
        func render(_ chars: Int) -> (NSImage, CGFloat) {
            makeLabelImage(title: MenuBarTitleComposer.compose(task: task, subtask: subtask,
                                                               mode: MenuBarPrefs.titleMode, maxChars: chars) + suffix)
        }
        let full = task.count + (subtask?.count ?? 0) + 3
        var best = render(full)
        if best.0.size.width <= limit { return best }
        var lo = 4, hi = full - 1
        best = render(lo)
        while lo <= hi {
            let mid = (lo + hi) / 2
            let candidate = render(mid)
            if candidate.0.size.width <= limit { best = candidate; lo = mid + 1 } else { hi = mid - 1 }
        }
        return best
    }

    /// Nothing next: a check-circle glyph + a short calm "All clear" title, rendered through the SAME
    /// composite-image path as a real focus so the circle's hit region is always measured
    /// the same way regardless of which state is showing.
    private func allClearImage() -> (NSImage, CGFloat) {
        let title = String(localized: "menubar.allclear")
        return makeLabelImage(title: title, symbol: "checkmark.circle")
    }

    /// Renders `MenuBarStatusLabel` offscreen to a template `NSImage` — an `NSStatusItem`
    /// button takes an image, not a SwiftUI view, so the label is captured once per focus
    /// change rather than reimplemented as raw AppKit drawing. Never a count badge, never
    /// coloured — the bar's only content is the composed title (all-clear fallback). Also
    /// measures the glyph's own rendered width (a second, glyph-only pass at the same scale)
    /// so `clicked(_:)` can tell a circle click from a title click without hard-coding a
    /// pixel constant that could silently drift from what is actually drawn.
    private func makeLabelImage(title: String?, symbol: String = "circle") -> (NSImage, CGFloat) {
        let view = MenuBarStatusLabel(title: title, symbolName: symbol)
            .foregroundStyle(Tok.textPrimary)
            .fixedSize()
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return (NSImage(), 0) }
        let image = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2))
        image.isTemplate = true

        let glyphRenderer = ImageRenderer(content: Icon(symbol, size: Metrics.iconM).fixedSize())
        glyphRenderer.scale = 2
        let glyphWidth = glyphRenderer.cgImage.map { CGFloat($0.width) / 2 } ?? 0
        return (image, glyphWidth)
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { showPopover(focusCapture: false); return }
        if event.type == .rightMouseUp {
            showMenu()
            return
        }
        let localX = sender.convert(event.locationInWindow, from: nil).x
        let imageOrigin = max(0, (sender.bounds.width - (sender.image?.size.width ?? 0)) / 2)
        if MenuBarHitRegion.region(forX: localX, circleWidth: circleWidth, imageOrigin: imageOrigin, slop: Space.x2,
                                   titleGap: Space.x1) == .circle {
            completeFromBar()
        } else {
            showPopover(focusCapture: false)
        }
    }

    /// Same store path as the popover's own Complete control (`PopoverContent.complete()`):
    /// the next open subtask first, else the task itself; clears a pin that completes; posts
    /// the same notification so sound/undo behave identically regardless of which control
    /// fired the completion.
    private func completeFromBar() {
        guard let focus = resolvedFocus(), let task = model.store.task(focus.id) else { return }
        if let next = task.nextOpenSubtask {
            model.store.toggleSubtask(next.id)
        } else {
            model.store.complete(focus.id)
            if model.pinnedFocusTaskID == focus.id { model.pinnedFocusTaskID = nil }
        }
        model.didMutate()
        // Shell-level pill too (KUndoPill.swift): the main window may be open behind the
        // menu bar, and it would otherwise show nothing for a completion made from here.
        UndoToastCenter.shared.show(String(format: String(localized: "undo.completed.name"), task.title))
        NotificationCenter.default.post(name: .kronosDidCompleteFromBar, object: nil)
    }

    /// `focusCapture: true` (meeting-capture hotkey) opens the popover with the capture
    /// field already focused, so typing can start the instant it appears — capture is meant
    /// to always be available from the menu bar.
    private func showPopover(focusCapture: Bool) {
        guard let button = statusItem?.button else { return }
        if let popover, popover.isShown {
            if focusCapture { NotificationCenter.default.post(name: .kronosMenuBarFocusCaptureField, object: nil) }
            return
        }
        let popover = makePopover(focusCapture: focusCapture)
        self.popover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NotificationCenter.default.post(name: .kronosOrdoPopoverShown, object: nil)
    }

    /// The popover exactly as the status item shows it. The system draws the frame and arrow: dark aqua
    /// keeps them dark, so no grey material shows around the black content.
    private func makePopover(focusCapture: Bool) -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: PopoverContent(model: model, quiet: quiet, focusCaptureOnAppear: focusCapture))
        return popover
    }

    #if !RELEASE
    /// Live UI test seam: the real popover, shown from a view of the test window (a VM has no status
    /// item button to anchor to). Returns its window.
    func showPopoverForUITest(from anchor: NSView) -> NSWindow? {
        let popover = makePopover(focusCapture: false)
        self.popover = popover
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        return popover.contentViewController?.view.window
    }

    /// Closes that popover through NSPopover itself (closing only its window leaves the popover's
    /// transient-dismissal machinery attached to the test window and swallows later clicks).
    func closePopoverForUITest() { popover?.performClose(nil) }
    #endif

    private func showMenu() {
        let menu = NSMenu()
        for row in MenuBarMenuSpec.rows(hasFocus: resolvedFocus() != nil, quietLinesOn: MenuBarPrefs.quietLines) {
            if row.item == .separator { menu.addItem(.separator()); continue }
            let (key, action): (String, Selector) = {
                switch row.item {
                case .open: return ("bar.menu.open", #selector(openKronos))
                case .quickAdd: return ("menu.file.quickadd", #selector(newTask))
                case .pickOne: return ("menubar.menu.pickone", #selector(pickOne))
                case .completeCurrent: return ("menu.extra.complete", #selector(completeCurrent))
                case .quietLines: return ("menubar.quiet.toggle", #selector(toggleQuietLines))
                case .settings: return ("menubar.menu.settings", #selector(openSettings))
                case .quit, .separator: return ("menubar.menu.quit", #selector(quit))
                }
            }()
            let item = withKeyEquivalentAndAction(String(localized: String.LocalizationValue(key)), action)
            item.isEnabled = row.enabled
            item.state = row.checked ? .on : .off
            menu.addItem(item)
        }
        guard let button = statusItem?.button else { return }
        statusItem?.menu = menu
        button.performClick(nil)
        statusItem?.menu = nil
    }

    private func withKeyEquivalentAndAction(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openKronos() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.isVisible == false { window.makeKeyAndOrderFront(nil) }
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }

    @objc private func newTask() { AppDelegate.shared?.quickAdd.toggle() }

    /// Impuls ("Pick one"): bring the window forward and open the overlay.
    @objc private func pickOne() {
        openKronos()
        model.isImpulsOpen = true
    }

    @objc private func completeCurrent() { completeFromBar() }

    @objc private func openSettings() {
        openKronos()
        NotificationCenter.default.post(name: .kronosSettingsRequested, object: nil)
    }

    @objc private func toggleQuietLines() {
        MenuBarPrefs.quietLines.toggle()
        quiet.tick(model: model)
        render()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func popoverDidClose(_ notification: Notification) { popover = nil }
}
