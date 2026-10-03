// Kronos/Settings/SettingsScreen.swift
// Settings window content: a left tab rail (General / AI / MCP / Data / Shortcuts) on pure
// black, one content pane per tab. Hosted by the app shell in a `Settings { }` scene. Every
// row: label on one grid column, control on the other, one control height per row, quiet
// help text underneath where needed.

import AppKit
import SwiftUI
import KronosCore
import UniformTypeIdentifiers

/// Internal, not private: SettingsSnapshots.swift selects a starting tab (e.g. .ai) for the
/// snapshots that must show the rail with a non-default tab active.
///
/// Order: General (with the notes inbox, startup and updates), Appearance, Planning (sorting,
/// house rules, time blocks, the menu bar and the Up next presets), AI, MCP ("AI access"),
/// Agents, Data, Shortcuts. Eight tabs at most, so the rail stays short; the rarely changed
/// preferences of a tab sit under its Advanced disclosure.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, appearance, planning, ai, mcp, agents, data, shortcuts
    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .general: return "settings.tab.general"
        case .appearance: return "settings.tab.appearance"
        case .planning: return "settings.tab.planning"
        case .ai: return "settings.tab.ai"
        case .mcp: return "settings.tab.mcp"
        case .agents: return "settings.tab.agents"
        case .data: return "settings.tab.data"
        case .shortcuts: return "settings.tab.shortcuts"
        }
    }
    var icon: String {
        // "settings"/"keyboard" ARE real Icon.swift map keys (they resolve to
        // "gearshape"/"keyboard" respectively) — a prior comment here named
        // "gearshape"/"keyboard" as the missing raw names, when the actual map key spellings
        // "settings"/"keyboard" were never tried. Verified against Icon.symbol(for:) directly,
        // not from memory.
        switch self {
        case .general: return "settings"
        case .appearance: return "palette"
        case .planning: return "calendar"
        case .ai: return "sparkles"
        case .mcp: return "server"
        case .agents: return "users"
        case .data: return "database"
        case .shortcuts: return "keyboard"
        }
    }

    /// The pane the window opened on last time (a fresh install, or a pane that no longer
    /// exists, opens General). Kept in the hermetic defaults under a test run.
    private static let lastTabKey = "kronos.settings.lastTab"
    static var lastOpened: SettingsTab {
        KronosEnv.defaults.string(forKey: lastTabKey).flatMap(SettingsTab.init(rawValue:)) ?? .general
    }
    static func remember(_ tab: SettingsTab) {
        KronosEnv.defaults.set(tab.rawValue, forKey: lastTabKey)
    }
}

struct SettingsScreen: View {
    let model: AppModel
    @State private var tab: SettingsTab = .general
    @State private var aiController = AISettingsController()
    @FocusState private var paneFocused: Bool
    private let mcpStatus: MCPStatusProviding

    init(model: AppModel) {
        self.init(model: model, initialTab: Self.snapshotTab ?? SettingsTab.lastOpened)
    }

    private static var isSnapshot: Bool { ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT"] != nil }
    private var isSnapshot: Bool { Self.isSnapshot }

    /// Snapshot runs only: `KRONOS_SETTINGS_TAB=agents` opens that tab in the "settings" screen, so every
    /// tab can be shot with the rail around it without a registry entry of its own.
    private static var snapshotTab: SettingsTab? {
        guard isSnapshot, let raw = ProcessInfo.processInfo.environment["KRONOS_SETTINGS_TAB"] else { return nil }
        return SettingsTab(rawValue: raw)
    }

    /// Fixture rows under snapshots; the real store and live server otherwise.
    private func agentsController() -> AgentsSettingsController {
        AgentsSettingsController(live: Self.isSnapshot ? nil : AppDelegate.shared?.mcpLive,
                                 store: Self.isSnapshot ? nil : AppDelegate.shared?.store,
                                 fixture: Self.isSnapshot)
    }

    /// Snapshot-only entry point: SettingsSnapshots.swift needs the rail visible with a
    /// non-default tab selected (e.g. "settings.ai" per ui-common.md G4 "read the rail").
    /// The frozen `init(model:)` above is unaffected and still the only public surface.
    init(model: AppModel, initialTab: SettingsTab) {
        self.model = model
        self._tab = State(initialValue: Self.snapshotTab ?? initialTab)
        self.mcpStatus = ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT"] != nil
            ? FakeMCPStatusProvider(isRunning: true, port: 47311)
            : (AppDelegate.shared?.mcpLive ?? DefaultMCPStatusProvider())
    }

    var body: some View {
        HStack(spacing: 0) {
            railView
            KHairline(vertical: true)
            contentView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Tok.bg)
        // Default 900x640, user-resizable down to 900x560 (the Startup and Restore sections sat below the old fixed fold).
        .frame(minWidth: 900, idealWidth: 900, maxWidth: .infinity, minHeight: 560, idealHeight: 640, maxHeight: .infinity)
        // The Settings scene opens wherever AppKit last put it, often on the OTHER display.
        .background(WindowWidthReader { SettingsWindowPlacer.shared.attach($0) })
        .onAppear {
            // Snapshot-only: the "settings.ai" screen must show a passed Test result (G4),
            // and AISettingsController.runTest() is a no-op network call under
            // KRONOS_SNAPSHOT — it fills in a fixed result immediately. Never runs in the
            // real app on a fresh Settings open (that would be a surprise network call).
            guard ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT"] != nil, tab == .ai else { return }
            Task { await aiController.runTest() }
        }
        // A request that names a tab moves an open window there (a closed one reads the stored tab).
        .onReceive(NotificationCenter.default.publisher(for: .kronosSettingsRequested)) { note in
            guard let raw = note.userInfo?["tab"] as? String, let requested = SettingsTab(rawValue: raw) else { return }
            tab = requested
        }
    }

    private var railView: some View {
        VStack(alignment: .leading, spacing: Space.x1) {
            Text(String(localized: "settings.title"))
                .font(Typo.heading)
                .foregroundStyle(Tok.textPrimary)
                .padding(.horizontal, Space.x3)
                .padding(.top, Space.x4)
                .padding(.bottom, Space.x2)
            ForEach(SettingsTab.allCases) { t in
                railRow(t)
            }
            Spacer()
        }
        .frame(width: SettingsMetrics.railWidth)
        .padding(.horizontal, Space.x2)
        .background(Tok.surface)
    }

    private func railRow(_ t: SettingsTab) -> some View {
        Button {
            tab = t
            SettingsTab.remember(t)
        } label: {
            HStack(spacing: Space.x2) {
                Icon(t.icon, size: Metrics.iconM)
                    .foregroundStyle(tab == t ? Tok.textPrimary : Tok.textSecondary)
                    .accessibilityHidden(true)
                Text(String(localized: String.LocalizationValue(t.titleKey)))
                    .font(Typo.row)
                    .foregroundStyle(tab == t ? Tok.textPrimary : Tok.textSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .uiTestAnchor("settings.rail.label." + t.rawValue)
            }
            .padding(.horizontal, Space.x2)
            .frame(height: Metrics.sidebarRowHeight)
            .background(
                RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                    .fill(tab == t ? Tok.selectedFill : Color.clear)
            )
            .contentShape(Rectangle())
            .uiTestAnchor("settings.rail." + t.rawValue)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(tab == t ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var contentView: some View {
        // GeometryReader supplies the ONE real width figure: a ScrollView always proposes
        // its content's ideal (unconstrained) width on the non-scrolling axis, so a plain
        // `.frame(maxWidth: .infinity)` inside it has nothing to expand into — every row
        // then sizes to its own widest control instead of sharing the pane's true width,
        // which is exactly why the trailing edges drifted apart (confirmed by screenshot).
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: Space.x6) {
                    switch tab {
                    case .general: SettingsGeneralTab(model: model)
                    case .appearance: SettingsAppearanceTab(model: model)
                    case .planning: SettingsPlanningTab(model: model)
                    case .ai: SettingsAITab(controller: aiController)
                    case .mcp: SettingsMCPTab(status: mcpStatus)
                    case .agents: SettingsAgentsTab(eager: isSnapshot) { agentsController() }
                    case .data: SettingsDataTab(model: model)
                    case .shortcuts: SettingsShortcutsTab()
                    }
                }
                .padding(Space.x6)
                .frame(width: geo.size.width, alignment: .leading)
            }
            // Focusable so Down/PageDown/Space scroll the pane from the keyboard; a new tab starts at the top.
            .focusable()
            .focused($paneFocused)
            .focusEffectDisabled()
            .id(tab)
            .onAppear { paneFocused = true }
        }
    }
}

/// Puts the Settings window on the screen that holds the main window, once per open (not on every
/// focus change, so dragging it elsewhere afterwards sticks until it is closed and reopened).
@MainActor
final class SettingsWindowPlacer {
    static let shared = SettingsWindowPlacer()
    private weak var window: NSWindow?
    private var needsPlacement = true
    private var tokens: [NSObjectProtocol] = []

    func attach(_ window: NSWindow?) {
        guard let window, window !== self.window else { return }
        self.window = window
        needsPlacement = true
        let nc = NotificationCenter.default
        tokens = [
            nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.placeIfNeeded() }
            },
            nc.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.needsPlacement = true }
            },
        ]
        placeIfNeeded()
    }

    private func placeIfNeeded() {
        guard needsPlacement, let window else { return }
        needsPlacement = false
        // The shell window is titled "Kronos" (KronosApp's Window scene); absent = leave AppKit's choice.
        guard let main = NSApp.windows.first(where: { $0 !== window && $0.title == "Kronos" && $0.isVisible }),
              let screen = main.screen, screen != window.screen else { return }
        let area = screen.visibleFrame
        window.setFrameOrigin(NSPoint(x: area.midX - window.frame.width / 2, y: area.midY - window.frame.height / 2))
    }
}

/// A language is called by its own name in every UI language.
enum SettingsLanguageName {
    static let english = "English"
    static let croatian = "Hrvatski"
}
