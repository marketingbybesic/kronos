// Kronos/Permissions/PermissionsWindow.swift
// The classic "Privacy & Permissions" style window every good Mac app has: one place that
// lists every system permission / connection Kronos uses, what it's for, its status, and
// one button to grant it. Never nags — no badges, no counts, no red, no "!". Reuses
// `model.coach.requestCalendarAccess()` for Calendar (never a second EventKit path).
import SwiftUI
import AppKit
import KronosCore

@Observable
@MainActor
final class PermissionsModel {
    private let statusProvider: PermissionsStatusProviding
    private let requestCalendarAccess: () async -> Void
    private let requestNotesAccess: () async -> Void
    private let enableLaunchAtLogin: () -> Void
    /// Set by `PermissionsWindow` once it knows how to switch to the MCP tab; the model has
    /// no notion of "tabs" itself, only that Claude access's button asks for one.
    var onOpenSettingsTab: () -> Void = {}
    private(set) var statuses: [PermissionKind: PermissionStatus] = [:]

    init(statusProvider: PermissionsStatusProviding,
         requestCalendarAccess: @escaping () async -> Void = {},
         requestNotesAccess: @escaping () async -> Void = {},
         enableLaunchAtLogin: @escaping () -> Void = {}) {
        self.statusProvider = statusProvider
        self.requestCalendarAccess = requestCalendarAccess
        self.requestNotesAccess = requestNotesAccess
        self.enableLaunchAtLogin = enableLaunchAtLogin
        refresh()
    }

    func refresh() {
        for kind in PermissionKind.allCases { statuses[kind] = statusProvider.status(for: kind) }
    }

    func status(for kind: PermissionKind) -> PermissionStatus { statuses[kind] ?? .notDetermined }

    func act(on kind: PermissionKind) {
        switch PermissionRowLogic.action(for: status(for: kind), kind: kind) {
        case .allow, .turnOn:
            allow(kind)
        case .openSystemSettings(let pane):
            openURL(pane)
        case .open(let url):
            openURL(url)
        case .openSettingsTab:
            onOpenSettingsTab()
        case .none:
            break
        }
    }

    /// The only place a tap can lead to a system prompt (Calendar's `requestAccess`, Notes'
    /// first AppleScript call). Both closures are no-ops under a snapshot/scratch store —
    /// `CoachModel.requestCalendarAccess()` and `OsaScriptNotesBridge` guard themselves the
    /// same way `SettingsCoachTab`/`SettingsNotesTab` already rely on.
    private func allow(_ kind: PermissionKind) {
        switch kind {
        case .calendar:
            Task { await requestCalendarAccess(); refresh() } // prompt-ok: only runs from this explicit button tap
        case .notes:
            Task { await requestNotesAccess(); refresh() } // prompt-ok: only runs from this explicit button tap
        case .launchAtLogin:
            enableLaunchAtLogin()
            refresh()
        default:
            break
        }
    }

    private func openURL(_ string: String) {
        guard !string.isEmpty, ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT"] == nil,
              let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}

struct PermissionsWindow: View {
    let model: PermissionsModel
    var onDone: () -> Void = {}

    init(model: PermissionsModel, onDone: @escaping () -> Void = {}) {
        self.model = model
        self.onDone = onDone
        // Claude access's row asks to land on the MCP tab specifically, but reuses the
        // existing no-argument "open Settings" signal rather than adding a tab argument to
        // `Kronos/Palette/PaletteNotifications.swift`. A small extension there would make
        // this exact.
        model.onOpenSettingsTab = {
            guard ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT"] == nil else { return }
            NotificationCenter.default.post(name: .kronosSettingsRequested, object: nil)
        }
    }

    private let rows: [PermissionKind] = [.calendar, .notes, .launchAtLogin, .siriShortcuts, .spotlight, .claudeAccess]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            KHairline()
            VStack(spacing: 0) {
                ForEach(rows) { kind in
                    PermissionRow(kind: kind, status: model.status(for: kind)) { model.act(on: kind) }
                    if kind != rows.last { KHairline() }
                }
            }
            .padding(.vertical, Space.x2)
            KHairline()
            footer
        }
        .frame(width: 520)
        .background(Tok.bg)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.x1) {
            HStack(spacing: Space.x2) {
                appIcon
                Text(String(localized: "permissions.title"))
                    .font(Typo.heading)
                    .foregroundStyle(Tok.textPrimary)
            }
            Text(String(localized: "permissions.intro"))
                .font(Typo.meta)
                .foregroundStyle(Tok.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            // A one-line note that macOS remembers each answer, distinct from
            // permissions.intro's "works without any of these" framing, so it stays a second
            // line rather than folding into it.
            Text(String(localized: "permissions.remembered", defaultValue: "macOS remembers each answer — change it any time in System Settings."))
                .font(Typo.meta)
                .foregroundStyle(Tok.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.x5)
    }

    /// The real app icon where available; a quiet glyph plate under the snapshot harness
    /// (no bundle icon exists there) so the row never renders blank.
    @ViewBuilder
    private var appIcon: some View {
        if ProcessInfo.processInfo.environment["KRONOS_SNAPSHOT"] == nil, let icon = NSApp.applicationIconImage {
            Image(nsImage: icon).resizable().frame(width: 28, height: 28)
        } else {
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(Tok.controlFill)
                .frame(width: 28, height: 28)
                .overlay(Icon("settings", size: Metrics.iconM).foregroundStyle(Tok.textSecondary))
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(String(localized: "common.done")) { onDone() }
                .kButton(.primary)
                .keyboardShortcut(.defaultAction)
        }
        .padding(Space.x4)
    }
}

private struct PermissionRow: View {
    let kind: PermissionKind
    let status: PermissionStatus
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: Space.x3) {
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(Tok.controlFill)
                .frame(width: 28, height: 28)
                .overlay(Icon(kind.icon, size: Metrics.iconM).foregroundStyle(Tok.textSecondary))

            VStack(alignment: .leading, spacing: Space.x1) {
                Text(String(localized: String.LocalizationValue(kind.titleKey)))
                    .font(Typo.rowStrong)
                    .foregroundStyle(Tok.textPrimary)
                Text(String(localized: String.LocalizationValue(kind.reasonKey)))
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(statusText)
                    .font(Typo.meta)
                    .foregroundStyle(Tok.textSecondary)
            }

            Spacer(minLength: Space.x2)

            trailingButton
        }
        .padding(.horizontal, Space.x5)
        .padding(.vertical, Space.x2)
        .background(isHovering ? Tok.hoverFill : Color.clear)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        switch status {
        case .granted: return String(localized: "permissions.status.granted")
        case .notDetermined: return String(localized: "permissions.status.notdetermined")
        case .denied: return String(localized: "permissions.status.denied")
        case .notNeeded: return String(localized: "permissions.status.notneeded")
        }
    }

    @ViewBuilder
    private var trailingButton: some View {
        switch PermissionRowLogic.action(for: status, kind: kind) {
        case .allow:
            Button(String(localized: "permissions.action.allow"), action: action)
                .kButton(.secondary, size: .compact)
                .fixedSize()
        case .turnOn:
            Button(String(localized: "permissions.action.turnon"), action: action)
                .kButton(.secondary, size: .compact)
                .fixedSize()
        case .openSystemSettings:
            Button(String(localized: "permissions.action.opensystem"), action: action)
                .kButton(.secondary, size: .compact)
                .fixedSize()
        case .open:
            Button(String(localized: "permissions.action.open"), action: action)
                .kButton(.secondary, size: .compact)
                .fixedSize()
        case .openSettingsTab:
            Button(String(localized: "permissions.action.opensettingstab"), action: action)
                .kButton(.secondary, size: .compact)
                .fixedSize()
        case .none:
            EmptyView()
        }
    }
}

/// Single-instance NSWindow host, so a second "Permissions…" click brings the same window
/// forward instead of stacking duplicates.
@MainActor
enum PermissionsWindowController {
    private static var window: NSWindow?

    /// Driver's one call site: builds the real `PermissionsModel` from the app's `AppModel`
    /// (Calendar via `model.coach`, Notes via `model.notes`, launch-at-login via
    /// `LaunchAtLogin`) and shows it. `mcpStatus` is the same provider `SettingsScreen`
    /// already constructs (`DefaultMCPStatusProvider()` / `FakeMCPStatusProvider` under
    /// `KRONOS_SNAPSHOT`) — pass the same instance so both windows agree.
    static func show(model: AppModel, mcpStatus: MCPStatusProviding) {
        let permModel = PermissionsModel(
            statusProvider: LivePermissionsStatus(model: model, mcpStatus: mcpStatus),
            requestCalendarAccess: { await model.coach.requestCalendarAccess() },
            requestNotesAccess: { _ = try? await model.notes.folders() },
            enableLaunchAtLogin: { LaunchAtLogin.setEnabled(true) })
        show(model: permModel)
    }

    static func show(model: PermissionsModel) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = PermissionsWindow(model: model, onDone: { window?.close() })
        let hosting = NSHostingController(rootView: view)
        let panel = NSWindow(contentViewController: hosting)
        panel.title = String(localized: "permissions.title")
        panel.styleMask = [.titled, .closable]
        panel.isReleasedWhenClosed = false
        panel.center()
        window = panel
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { _ in
            Task { @MainActor in window = nil }
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
