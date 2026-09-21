// Kronos/App/AppShellView.swift
// The three-pane window content: sidebar | list | inspector, on pure OLED black. A custom
// split (not NavigationSplitView) so the sidebar can width-animate between its two display
// modes and the inspector can collapse below a threshold while both keep a user-draggable
// width persisted across launches.
import AppKit
import SwiftUI
import KronosCore

struct AppShellView: View {
    @Environment(\.openSettings) private var openSettings
    let model: AppModel

    @State private var inspectorWidth: CGFloat = AppShellView.restoredInspectorWidth()
    @State private var userCollapsedInspector = false
    @State private var dragStartWidth: CGFloat?
    @State private var windowWidth: CGFloat = 1280
    /// Set once by `WindowWidthReader` (`viewDidMoveToWindow`) — THIS view's real window, never
    /// `NSApp.keyWindow` (wrong whenever Settings or the quick add panel is the key window
    /// instead of the main shell). `@State` so its holder (`WindowWidthObserver`) survives
    /// `AppShellView`'s own body re-evaluations without re-registering its notification
    /// observers on every redraw.
    @State private var windowWidthObserver = WindowWidthObserver()
    @State private var impulsMode: ImpulsScreen.Mode = .ask
    // Shell-level undo pill (KUndoPill.swift): completing/deleting from ANY screen — list,
    // Now card, inspector, triage, Impuls, menu bar — posts to `UndoToastCenter.shared`, and
    // this one overlay shows it regardless of which screen posted. `@Bindable` so `current`'s
    // `onChange`-free removal (nil-out) still drives the overlay's `if let` the same way a
    // local `@State` would.
    @Bindable private var undoCenter = UndoToastCenter.shared

    init(model: AppModel) { self.model = model }

    private var sidebarMode: KSidebarMode { model.sidebarIconsOnly ? .iconsOnly : .iconsAndText }

    /// Below this window width the inspector cannot fit alongside a usable list at the
    /// sidebar's current width without squeezing rows below their fixed internal geometry
    /// (KSidebarRow's spacing tokens assume their container is never narrower than the
    /// sidebar's own width) — so it auto-collapses rather than clipping.
    private var inspectorAutoCollapsed: Bool {
        windowWidth < sidebarMode.width + Metrics.listMin + Metrics.inspectorMin
    }
    private var inspectorCollapsed: Bool { userCollapsedInspector || inspectorAutoCollapsed }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                HStack(spacing: 0) {
                    SidebarScreen(model: model)
                        .frame(width: sidebarMode.width)
                        .environment(\.kSidebarMode, sidebarMode)
                        .animation(Motion.curve(Motion.medium), value: sidebarMode)

                    KHairline(vertical: true)

                    TaskListScreen(model: model)
                        .frame(minWidth: Metrics.listMin, maxWidth: .infinity, maxHeight: .infinity)

                    if !inspectorCollapsed {
                        inspectorDivider
                        InspectorScreen(model: model)
                            .frame(width: inspectorWidth)
                            .transition(.opacity)
                    }
                }

                if model.isTriageOpen {
                    overlayScrim { model.isTriageOpen = false }
                    // Vertically centred, unlike the palette/Impuls overlays which anchor to
                    // the top — triage is a single focused card, not a scrollable list, so
                    // centring reads calmer.
                    TriageFlowView(model: model, onClose: { model.isTriageOpen = false })
                        .padding(.horizontal, Space.x4)
                        .transition(.opacity)
                }

                if model.isTimeBlocksOpen {
                    overlayScrim { model.isTimeBlocksOpen = false }
                    TimeBlocksScreen(model: model)
                        .frame(width: Metrics.inspectorMax, height: Metrics.inspectorMax)
                        .kBorder(Tok.hairline, radius: Radius.card)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                        .transition(.opacity)
                }

                if model.isImpulsOpen {
                    overlayScrim { model.isImpulsOpen = false }
                    ImpulsScreen(model: model, mode: impulsMode, aiRouter: model.ai)
                        .frame(width: Metrics.inspectorDefault)
                        .kBorder(Tok.hairline, radius: Radius.card)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                        .transition(.opacity)
                }

                if model.isCaptureOpen {
                    overlayScrim { model.isCaptureOpen = false }
                    CaptureScreen(model: model)
                        .frame(width: Metrics.inspectorMax, height: Metrics.inspectorMax)
                        .kBorder(Tok.hairline, radius: Radius.card)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                        .transition(.opacity)
                }

                if model.isPaletteOpen {
                    overlayScrim { model.isPaletteOpen = false }
                    // The palette sizes and clips ITSELF (max 560, narrower in a small window).
                    // A second, narrower frame + clip here cut its left edge off.
                    CommandPaletteView(model: model)
                        .padding(.horizontal, Space.x4)
                        .padding(.top, Space.x8)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .transition(.opacity)
                }

                // This used to be a `.sheet(...)`, an AppKit system sheet that draws its own
                // vibrancy/material chrome regardless of this view's own background — the one
                // overlay in the shell that ever looked "glassy". Every sibling overlay here
                // (Triage/Impuls/Capture/Palette) is a plain scrim + card instead; the keymap
                // card now matches them (KeymapReferenceView itself owns its size/card chrome,
                // same as CommandPaletteView above).
                if model.isKeymapOpen {
                    overlayScrim { model.isKeymapOpen = false }
                    KeymapReferenceView { model.isKeymapOpen = false }
                        .padding(.horizontal, Space.x4)
                        .padding(.top, Space.x8)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .transition(.opacity)
                }

                if let toast = undoCenter.current {
                    KUndoPill(message: toast.message, onUndo: {
                        model.store.undo(); model.didMutate(); undoCenter.dismiss()
                    }, onExpire: {
                        undoCenter.expire(toast.id)
                    })
                    .padding(.bottom, Space.x4)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .uiTestAnchor("undo.pill")
                    .transition(.opacity)
                }
            }
            .background(WindowWidthReader { windowWidthObserver.attach(to: $0) })
            .onAppear { offerMorningPlanIfDue() }
            .onChange(of: model.scope) { _, _ in offerMorningPlanIfDue() }
            .onChange(of: model.isImpulsOpen) { _, open in if !open { impulsMode = .ask } }
            .onChange(of: windowWidthObserver.width) { _, newValue in
                if let newValue { windowWidth = newValue }
            }
        }
        .background(Tok.bg)
        // The ONE injection point for the colour mode; the design system resolves every tint from it.
        .environment(\.chromaMode, model.chromaMode)
        .environment(\.kAccent, Accent.resolve(model.coach.settings.accentHex, mode: model.chromaMode))
        // Caret + text-selection tint follows the chosen accent everywhere in this window: the
        // ONE root `.tint` for every TextField/TextEditor in the shell's tree, including the
        // list row's inline title editor. Separate roots (QuickAdd's NSPanel, the shortcuts
        // sheet, Settings' own window scene) are outside this view and need the same line
        // wherever they are defined.
        .tint(Accent.resolve(model.coach.settings.accentHex, mode: model.chromaMode))
        .animation(Motion.curve(Motion.medium), value: inspectorCollapsed)
        .animation(Motion.curve(Motion.fast), value: model.isImpulsOpen)
        .animation(Motion.curve(Motion.fast), value: model.isPaletteOpen)
        .animation(Motion.curve(Motion.fast), value: model.isCaptureOpen)
        .animation(Motion.curve(Motion.fast), value: model.isTimeBlocksOpen)
        .animation(Motion.curve(Motion.fast), value: undoCenter.current)
        .animation(Motion.curve(Motion.fast), value: model.isKeymapOpen)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("kronosCapturePrefillRequested"))) { note in
            // Menu-bar meeting capture and Siri hand their text over here.
            model.openCapture(with: note.userInfo?["text"] as? String)
        }
        .onReceive(NotificationCenter.default.publisher(for: .kronosSettingsRequested)) { _ in
            // The private showSettingsWindow: selector stopped working on macOS 14; this is the
            // supported action. Every caller (sidebar, menu bar, palette) posts the notification.
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .onReceive(NotificationCenter.default.publisher(for: .kronosKeymapRequested)) { _ in
            model.isKeymapOpen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .kronosToggleInspectorRequested)) { _ in
            toggleInspector()
        }
        // Selection hygiene: the task list validates selection against its own visible rows
        // and re-selects there when appropriate — this only clears a selection that is now
        // certainly stale because the whole scope changed under it.
        .onChange(of: model.scope) { _, _ in
            model.selectedTaskID = nil
        }
        .onExitCommand {
            // Esc cascade: an overlay or popover consumes this via its own .onExitCommand
            // deeper in the view tree (SwiftUI runs the most specific handler) — Impuls/palette
            // close on their own, so reaching here means one of those was open, or nothing
            // was: close whichever overlay is open, else clear selection.
            if model.isKeymapOpen { model.isKeymapOpen = false }
            else if model.isPaletteOpen { model.isPaletteOpen = false }
            else if model.isCaptureOpen { model.isCaptureOpen = false }
            else if model.isTriageOpen { model.isTriageOpen = false }
            else if model.isTimeBlocksOpen { model.isTimeBlocksOpen = false }
            else if model.isImpulsOpen { model.isImpulsOpen = false }
            else { model.selectedTaskID = nil }
        }
    }

    /// Dimmed backdrop behind Impuls / the command palette (black 60%, ledger). Tapping it
    /// dismisses, matching Esc.
    private func overlayScrim(dismiss: @escaping () -> Void) -> some View {
        Tok.bg.opacity(0.6)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture(perform: dismiss)
            .transition(.opacity)
    }

    // MARK: Inspector resize + collapse

    private var inspectorDivider: some View {
        KHairline(vertical: true)
            .frame(width: Metrics.hitSlop * 2)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartWidth ?? inspectorWidth
                        if dragStartWidth == nil { dragStartWidth = inspectorWidth }
                        let proposed = start - value.translation.width
                        if proposed < Metrics.inspectorMin * 0.6 {
                            userCollapsedInspector = true
                        } else {
                            userCollapsedInspector = false
                            inspectorWidth = min(Metrics.inspectorMax, max(Metrics.inspectorMin, proposed))
                        }
                    }
                    .onEnded { _ in
                        dragStartWidth = nil
                        Self.persistInspectorWidth(inspectorWidth)
                    }
            )
    }

    private func toggleInspector() {
        withAnimation(Motion.curve(Motion.medium)) { userCollapsedInspector.toggle() }
    }

    // MARK: Persistence — small UI-only geometry, same key style as AppModel's own UserDefaults use.

    private static let inspectorWidthKey = "kronos.ui.inspectorWidth"

    private static func restoredInspectorWidth() -> CGFloat {
        let stored = UserDefaults.standard.double(forKey: inspectorWidthKey)
        guard stored >= Metrics.inspectorMin, stored <= Metrics.inspectorMax else { return Metrics.inspectorDefault }
        return stored
    }

    private static func persistInspectorWidth(_ width: CGFloat) {
        UserDefaults.standard.set(Double(width), forKey: inspectorWidthKey)
    }
}

extension Notification.Name {
    /// Posted by View > Inspector (⌘I / ⌥⌘0). Declared alongside the shell that owns the
    /// only view observing it.
    static let kronosToggleInspectorRequested = Notification.Name("kronosToggleInspectorRequested")

}

extension AppShellView {
    // MARK: Morning plan (spec 7.1): once a day, on the first visit to Today or Inbox, when there
    // are at least three open tasks. Settings > Coach switches it off. Never in snapshot runs.
    private func offerMorningPlanIfDue() {
        guard ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT"] == nil else { return }
        let d = UserDefaults.standard
        let enabled = AppearancePrefs.morningPlanEnabled
        guard enabled, model.scope == .today || model.scope == .inbox, !model.isImpulsOpen else { return }
        let last = d.object(forKey: "kronos.coach.morningLastShownDay") as? Int
        guard ImpulsScreen.shouldOfferMorning(now: Date(), lastShownDay: last) else { return }
        let open = model.store.allTasks().filter { $0.deletedAt == nil && KStatus.open.contains($0.status) }
        guard open.count >= 3 else { return }
        d.set(Day.today(), forKey: "kronos.coach.morningLastShownDay")
        impulsMode = .morning
        model.isImpulsOpen = true
    }
}
