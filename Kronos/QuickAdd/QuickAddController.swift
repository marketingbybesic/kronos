// Kronos/QuickAdd/QuickAddController.swift
// Global-hotkey quick-add panel (spec §4): a non-activating NSPanel over any app,
// running the one QuickAddParser grammar live and showing its result as chips.
// Return creates via `model.store.create` and keeps the panel open (rapid dump,
// spec §2.3); Esc or click-outside closes and returns focus to the previous app.

import AppKit
import SwiftUI
import KeyboardShortcuts
import KronosCore

extension KeyboardShortcuts.Name {
    // Defaults come from HotkeyRegistry (Kronos/Hotkeys/), the single source of truth for
    // every shortcut — `globalShortcut` converts the registry's clash-free Ctrl-Opt-K/M/O
    // defaults (the old ⌥Space default collides with Raycast/Alfred/ChatGPT/Claude quick
    // entry on most Macs). `HotkeyRegistry.migrateLegacyQuickAddDefaultIfNeeded()` moves a
    // user who never customised the old default onto the new one, once, silently.
    static let quickAdd = Self("quickAdd", default: HotkeyRegistry.entries.first { $0.id == "global.quickadd" }!.defaultBinding.globalShortcut!)
    static let meetingCapture = Self("meetingCapture", default: HotkeyRegistry.entries.first { $0.id == "global.meetingcapture" }!.defaultBinding.globalShortcut!)
    static let showOrdo = Self("showOrdo", default: HotkeyRegistry.entries.first { $0.id == "global.showordo" }!.defaultBinding.globalShortcut!)
}

/// REVIEW FIX (critical): a plain `.borderless` `NSPanel` returns `canBecomeKey == false` by
/// default (AppKit), so it could never actually take key status — `makeKeyAndOrderFront` would
/// order it front but never make it key, the `TextEditor` inside would never become first
/// responder, and `windowDidResignKey` would never fire (so Esc-by-clicking-away would also never
/// close it). Nothing about this shows up in a snapshot (`SnapshotHarness` renders the SwiftUI
/// view directly into its own window, never through this class). `canBecomeMain` stays false: a
/// floating quick-entry panel should never become the app's main window (that would steal the
/// menu bar's window-menu identity from the real shell window).
private final class QuickAddPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// `NSHostingView` has no public "my ideal size just changed" callback, and `frameDidChange`
/// only fires from a frame WE set, not from SwiftUI's own internal re-layout. AppKit calls
/// `layout()` on every pass where this view's content may have changed size (SwiftUI re-render
/// included), so hooking it here is the one reliable point to notice the legend/chips/outline
/// resizing the card and tell the window to follow — every other approach (frame KVO, a Timer,
/// re-checking on every keystroke from the SwiftUI side) is either unreliable or adds a dependency
/// this view doesn't need.
private final class QuickAddHostingView: NSHostingView<AnyView> {
    var onLayout: (() -> Void)?
    override func layout() {
        super.layout()
        onLayout?()
    }
}

@MainActor
final class QuickAddController: NSObject, NSWindowDelegate {
    let model: AppModel

    private var panel: NSPanel?
    private var previousApp: NSRunningApplication?
    private var hotkeyNotice: String?

    init(model: AppModel) { self.model = model }

    /// Registers the global hotkeys. Called once from `AppDelegate`. A conflicting or
    /// failed registration never surfaces as an alert — the panel shows a calm inline
    /// notice instead, the next time it opens (spec: never a modal for this).
    ///
    /// Meeting capture (`global.meetingcapture`) and show-Ordo (`global.showordo`) are
    /// registered here per their `HotkeyRegistry` entries; this file only posts the
    /// notification (observed elsewhere, in the menu-bar cockpit and triage) to actually
    /// act on it.
    func start() {
        HotkeyRegistry.migrateLegacyQuickAddDefaultIfNeeded()
        repairQuickAddShortcutIfMigrationDisabledIt()

        KeyboardShortcuts.onKeyUp(for: .quickAdd) { [weak self] in self?.toggle() }
        if KeyboardShortcuts.getShortcut(for: .quickAdd) == nil {
            hotkeyNotice = String(localized: "quickadd.hint.return")
        }

        KeyboardShortcuts.onKeyUp(for: .meetingCapture) {
            NotificationCenter.default.post(name: .kronosMeetingCaptureRequested, object: nil)
        }
        KeyboardShortcuts.onKeyUp(for: .showOrdo) {
            NotificationCenter.default.post(name: .kronosShowOrdoRequested, object: nil)
        }
    }

    /// Root cause of a real bug where the quick-add shortcut silently stopped working:
    /// `HotkeyRegistry.migrateLegacyQuickAddDefaultIfNeeded()` calls
    /// `KeyboardShortcuts.reset(.quickAdd)` for
    /// anyone who still had the old ⌥Space default. `KeyboardShortcuts.reset` does NOT clear the
    /// stored value when the `Name` has a `defaultShortcut` (it does for `.quickAdd`, set in this
    /// file) — it writes the boolean `false` as a "disabled" sentinel instead
    /// (`KeyboardShortcuts.userDefaultsDisable`, confirmed by reading the package source at
    /// `SourcePackages/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/KeyboardShortcuts.swift:464-473`).
    /// `Name.init`'s `default:` only writes on the very first launch ever
    /// (`!userDefaultsContains`), and a stored `false` counts as "contains" — so after that one
    /// `reset()` call the shortcut is permanently unset, on every future launch, for anyone who
    /// went through the migration. `SettingsShortcutsTab`'s `KeyboardShortcuts.Recorder(for:
    /// .quickAdd)` hits the identical package code path when a user clears it deliberately, and
    /// that state is indistinguishable from the bug once written — so this repair only ever runs
    /// once, gated on our OWN one-shot flag, and never fights a later deliberate clear.
    private static let repairedQuickAddKey = "kronos.quickadd.repairedMigrationDisable.v1"

    private func repairQuickAddShortcutIfMigrationDisabledIt() {
        let defaults = UserDefaults.standard
        let alreadyRepaired = defaults.bool(forKey: Self.repairedQuickAddKey)
        let isSnapshot = ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT"] != nil
        let hasShortcut = KeyboardShortcuts.getShortcut(for: .quickAdd) != nil
        guard QuickAddShortcutRepair.shouldRepair(alreadyRepaired: alreadyRepaired, isSnapshot: isSnapshot,
                                                   hasShortcut: hasShortcut) else { return }
        defaults.set(true, forKey: Self.repairedQuickAddKey)
        guard let fallback = HotkeyRegistry.entries.first(where: { $0.id == "global.quickadd" })?.defaultBinding.globalShortcut
        else { return }
        // `setShortcut` writes a real encoded value (unlike `reset`, which re-triggers the same
        // disable path for a Name that has a default), so this actually restores the hotkey.
        KeyboardShortcuts.setShortcut(fallback, for: .quickAdd)
    }

    func toggle() {
        if let panel, panel.isVisible { close(); return }
        open()
    }

    private func open() {
        previousApp = NSWorkspace.shared.frontmostApplication
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if Motion.reduceMotion {
            panel.alphaValue = 1
        } else {
            panel.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Motion.fast
                panel.animator().alphaValue = 1
            }
        }
    }

    private func close() {
        guard let panel else { return }
        if Motion.reduceMotion {
            finishClose(panel)
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Motion.fast
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.finishClose(panel) }
            }
        }
    }

    private func finishClose(_ panel: NSPanel) {
        panel.orderOut(nil)
        previousApp?.activate()
        previousApp = nil
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let x = frame.midX - size.width / 2
        let y = frame.minY + frame.height * 0.66 - size.height / 2
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func makePanel() -> NSPanel {
        // ROOT CAUSE of a real bug where an empty strip/rule showed above the input:
        // `titlebarSeparatorStyle = .none` only hides the HAIRLINE the titlebar draws —
        // `.titled` + `.fullSizeContentView` still RESERVES titlebar height (traffic-light
        // row) above the content, which reads as a blank strip even with no visible line or
        // title text (`titleVisibility = .hidden` already hid the text, not the space). This
        // panel shows no title, has no traffic lights, and is dragged via
        // `isMovableByWindowBackground` (not the titlebar), so the titlebar was pure vestige —
        // dropping `.titled` removes the reserved space itself, not just its hairline.
        //
        // REVIEW FIX: `.borderless` alone made the window SQUARE — `backgroundColor = .black`
        // filled the panel's own rectangular backing, which peeked out past the SwiftUI card's
        // rounded corners (the card paints its own `Tok.overlay` fill inside its own rounded
        // shape, one layer up). `isOpaque = false` + `backgroundColor = .clear` makes the panel
        // itself invisible outside the card's own paint, so only the card's rounded shape and
        // its own shadow-casting content are ever seen.
        let accent = Accent.resolve(model.coach.settings.accentHex, mode: model.chromaMode)
        let hostingView = QuickAddHostingView(rootView: AnyView(QuickAddPanelView(
            model: model,
            hotkeyNotice: hotkeyNotice,
            onSubmit: { [weak self] in self?.previousApp?.activate() },
            onClose: { [weak self] in self?.close() }
        )
            // Separate root from the shell (its own NSPanel/NSHostingView), so it needs the
            // same accent injection AppShellView.swift gives the main window.
            .environment(\.kAccent, accent)
            .tint(accent)
        ))
        // `fittingSize` measures the SwiftUI root's own ideal size — the card already fixes its
        // width to 720 (QuickAddPanelView.swift), so this reports the height that content needs
        // (empty legend / typed chips / a multi-line outline all differ) instead of the old
        // hardcoded 560x120 contentRect, which never matched the 720-wide card at all and left
        // the hosting view either clipped or floating in dead space depending on content.
        let fitSize = hostingView.fittingSize
        hostingView.frame = NSRect(origin: .zero, size: fitSize)

        let panel = QuickAddPanel(contentRect: NSRect(origin: .zero, size: fitSize),
                                   styleMask: [.nonactivatingPanel, .borderless],
                                   backing: .buffered, defer: false)
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.delegate = self
        panel.contentView = hostingView
        // `[weak self, weak panel, weak hostingView]`: this closure is retained BY the hosting
        // view, so capturing it strongly would be a retain cycle (view -> closure -> view).
        hostingView.onLayout = { [weak self, weak panel, weak hostingView] in
            self?.fitPanel(panel, to: hostingView)
        }
        return panel
    }

    /// Re-fits the panel to the card's new height whenever SwiftUI's own layout changes it
    /// (legend shown/hidden, chips appearing, a multi-line outline growing) — the panel has no
    /// height of its own beyond what its content needs. TOP edge fixed, grows/shrinks
    /// downward, matching how a dropdown/popover anchored at its top would behave, never
    /// re-jumping the input someone is looking at.
    private func fitPanel(_ panel: NSPanel?, to hostingView: NSHostingView<AnyView>?) {
        guard let panel, let hostingView else { return }
        let newSize = hostingView.fittingSize
        // Half-point tolerance: fittingSize can be fractional while the frame is pixel-rounded,
        // and an exact compare would resize on every layout pass.
        guard abs(newSize.height - panel.frame.height) > 0.5 || abs(newSize.width - panel.frame.width) > 0.5 else { return }
        let oldFrame = panel.frame
        let newOriginY = oldFrame.origin.y + oldFrame.height - newSize.height
        panel.setFrame(NSRect(x: oldFrame.origin.x, y: newOriginY, width: newSize.width, height: newSize.height),
                        display: true)
        panel.invalidateShadow()
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}
