// Kronos/QuickAdd/QuickAddController.swift
// Global-hotkey quick-add panel (spec §4): a non-activating NSPanel over any app,
// running the one QuickAddParser grammar live and showing its result as chips.
// Return creates and closes (focus goes back to the app it was opened over); Command-Return
// creates and stays open for the next thought; Option-Return creates and keeps the pills;
// Return on an empty field closes (QuickAddPolicy). Esc closes and returns focus too; a click
// into another app closes WITHOUT re-activating the previous app (that click chose the focus).
// Opened over another app, the panel reads that app's context once (QuickAddContextLive.swift):
// selected text or a page title / mail subject as the starting title, link chips to attach.

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
    /// The entry field of the panel as last opened (text, pills, suggestions). Read by the live UI test.
    private(set) var entry: EntryFieldModel?
    /// The context chips of the panel as last opened. Read by the live UI test.
    private(set) var context: QuickAddContextState?
    private var previousApp: NSRunningApplication?
    private var hotkeyNotice: String?
    /// Where context is read from. Nothing is read under a snapshot, the live UI test or a
    /// scratch store; the live test injects a scripted environment and `frontAppOverride`.
    var contextEnvironment: QuickAddContextEnvironment = KronosEnv.isHermetic
        ? NullQuickAddContextEnvironment() : LiveQuickAddContextEnvironment()
    /// Live UI test only: the app the panel pretends it was opened over.
    var frontAppOverride: QuickAddFrontApp?
    /// How many tasks quick add has created so far (the legend opens by itself for the first
    /// few, QuickAddPolicy.legendAutoOpenAdds).
    static let addsCountKey = "kronos.quickadd.addsCount"

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
            hotkeyNotice = String(localized: "quickadd.hint.noshortcut")
        }

        KeyboardShortcuts.onKeyUp(for: .meetingCapture) {
            NotificationCenter.default.post(name: .kronosMeetingCaptureRequested, object: nil)
        }
        KeyboardShortcuts.onKeyUp(for: .showOrdo) {
            NotificationCenter.default.post(name: .kronosShowOrdoRequested, object: nil)
        }
        // Palette "New from template…": open fresh with `/` typed so the template list shows.
        NotificationCenter.default.addObserver(forName: .kronosNewFromTemplate, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                QuickAddDraft.text = "/"; QuickAddDraft.closedAt = Date()
                self.open()
            }
        }
        // "Start here" > Show me opens THIS panel (the one the quest teaches), not the list's
        // inline row: `kronosNewTaskRequested` only ever focused that row.
        NotificationCenter.default.addObserver(forName: .kronosQuickAddPanelRequested, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !(self.panel?.isVisible ?? false) else { return }
                self.open()
            }
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
        if let panel, panel.isVisible { close(.finished); return }
        open()
    }

    /// The app the panel opens over, for the context reader; nil over Kronos itself.
    private func frontApp(kronosIsFrontmost: Bool) -> QuickAddFrontApp? {
        if let frontAppOverride { return frontAppOverride }
        guard !kronosIsFrontmost, let app = previousApp else { return nil }
        return QuickAddFrontApp(bundleID: app.bundleIdentifier, pid: app.processIdentifier,
                                name: app.localizedName ?? app.bundleIdentifier ?? "")
    }

    /// The destination pill a fresh panel starts with: the project or area list Kronos itself is
    /// showing, when Kronos is the app the panel was opened over. Over any other app, or on a
    /// fixed list (Inbox, Today ...), no pill: a task with no destination keeps its old meaning.
    static func prefilledPills(scope: ListScope, store: TaskStore, kronosIsFrontmost: Bool) -> [EntryPill] {
        guard kronosIsFrontmost else { return [] }
        switch scope {
        case .project(let id):
            guard let p = store.allProjects().first(where: { $0.id == id }) else { return [] }
            return [.destination(EntryDestination(kind: .project, name: p.name, id: p.id))]
        case .area(let id):
            guard let a = store.allAreas().first(where: { $0.id == id }) else { return [] }
            return [.destination(EntryDestination(kind: .area, name: a.name, id: a.id))]
        default:
            return []
        }
    }

    private func open() {
        previousApp = NSWorkspace.shared.frontmostApplication
        let kronosIsFrontmost = previousApp?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // Fresh root per open: clears text/legend/waiting, re-runs onAppear focus, and re-reads
        // whether the global shortcut is currently set (the notice used to be frozen at launch).
        hotkeyNotice = KeyboardShortcuts.getShortcut(for: .quickAdd) == nil ? String(localized: "quickadd.hint.noshortcut") : nil
        let seed = QuickAddDraft.takeSeed()
        // "/" is the palette's template opener, not a restored thought: no Draft caption, no selection.
        let entry = EntryFieldModel(text: seed,
                                    pills: Self.prefilledPills(scope: model.scope, store: model.store,
                                                               kronosIsFrontmost: kronosIsFrontmost),
                                    catalog: EntryCatalog.make(store: model.store))
        self.entry = entry
        // Context of the app the panel opens over: read once, in the background; a starting
        // title only lands while the field is still empty (a restored draft or typing wins).
        let front = frontApp(kronosIsFrontmost: kronosIsFrontmost)
        let context = QuickAddContextState(environment: contextEnvironment, front: front)
        context.onPrefill = { [weak entry] title in
            guard let entry, entry.text.isEmpty else { return }
            entry.setText(title, caret: title.utf16.count)
            entry.selectAllText()
            // The text view may attach a moment later (a fast answer lands before it): select
            // again then, so typing still replaces the starting title.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak entry] in
                guard let entry, entry.text == title else { return }
                entry.selectAllText()
            }
        }
        context.askConsent = { [weak self, weak context] in
            guard let self, let context else { return }
            self.askConsent(context)
        }
        self.context = context
        if front != nil { Task { await context.read() } }
        if let host = panel.contentView as? QuickAddHostingView {
            host.rootView = makeRoot(seed: seed, isDraft: seed != "/", entry: entry, context: context)
        }
        position(panel)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // The field's autofocus runs from onAppear, which can land before the panel is key; then
        // typing went nowhere (the panel itself stayed first responder). Make sure, once the text
        // view is attached (it attaches asynchronously), that the caret is in the field.
        for delay in [0.15, 0.45] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak entry, weak panel] in
                guard let entry, let panel, panel.isVisible, panel.isKeyWindow else { return }
                entry.focusTextView()
            }
        }
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

    /// `.finished` (Esc, Return, the hotkey) gives focus back to the app the panel was opened
    /// over; `.resignedKey` (a click elsewhere) leaves focus where that click put it.
    private func close(_ reason: QuickAddPolicy.CloseReason) {
        guard let panel, panel.isVisible, !isClosing else { return }
        isClosing = true
        let reactivate = QuickAddPolicy.reactivatesPreviousApp(reason)
        if Motion.reduceMotion {
            finishClose(panel, reactivate: reactivate)
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Motion.fast
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.finishClose(panel, reactivate: reactivate) }
            }
        }
    }

    private var isClosing = false

    private func finishClose(_ panel: NSPanel, reactivate: Bool) {
        isClosing = false
        QuickAddDraft.closedAt = Date()
        panel.orderOut(nil)
        if reactivate { previousApp?.activate() }
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

    private func makeRoot(seed: String, isDraft: Bool = false, entry: EntryFieldModel? = nil,
                          context: QuickAddContextState? = nil) -> AnyView {
        let accent = Accent.resolve(model.coach.settings.accentHex, mode: model.chromaMode)
        return AnyView(QuickAddPanelView(
            model: model,
            hotkeyNotice: hotkeyNotice,
            seedText: seed,
            seedIsDraft: isDraft,
            entry: entry,
            context: context,
            // Return (plain) after an add, or on an empty field: the panel's job is done and
            // focus goes back to the app it was opened over. Command-/Option-Return stay open
            // and never call this (QuickAddPanelView.submit, QuickAddPolicy.onReturn).
            onSubmit: { [weak self] in self?.close(.finished) },
            onClose: { [weak self] in self?.close(.finished) }
        )
            // Separate root from the shell (its own NSPanel/NSHostingView), so it needs the
            // same accent injection AppShellView.swift gives the main window.
            .environment(\.kAccent, accent)
            .tint(accent)
            .id(UUID()))  // new identity = fresh @State; same-typed AnyView would otherwise keep the old text
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
        let hostingView = QuickAddHostingView(rootView: makeRoot(seed: ""))
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
        // The system's Automation prompt takes key while the consent chip waits for an answer;
        // that is not "the person clicked away".
        guard !isAskingConsent else { return }
        close(.resignedKey)
    }

    private var isAskingConsent = false

    /// The consent chip: the one place a context read may show the system prompt. The panel
    /// stays open through the prompt and takes key back afterwards.
    private func askConsent(_ context: QuickAddContextState) {
        guard !isAskingConsent else { return }
        isAskingConsent = true
        Task { [weak self] in
            await context.read(ask: true)
            guard let self else { return }
            self.isAskingConsent = false
            if let panel = self.panel, panel.isVisible {
                panel.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                self.entry?.focusTextView()
            }
        }
    }
}
