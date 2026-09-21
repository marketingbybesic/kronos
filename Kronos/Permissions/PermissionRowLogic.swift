// Kronos/Permissions/PermissionRowLogic.swift
// The pure part of the permissions window: statuses, row kinds and the one-button decision
// table. Foundation only, so scripts/permissions-selftest.swift can compile the real file.
import Foundation

/// One permission/connection row's current state. Reading it must never raise a system
/// prompt (G5) — `.notDetermined` just means "not asked yet", not "asking now".
enum PermissionStatus: Equatable {
    case granted
    case notDetermined
    case denied
    /// Nothing to grant — an informational row (Siri & Shortcuts, Spotlight).
    case notNeeded
}

/// What a row's single button does, purely a function of its status. Kept as a pure
/// function (`PermissionRowLogic.action`) so `scripts/permissions-selftest.swift` can prove
/// every status maps to exactly one action without booting SwiftUI or EventKit.
enum PermissionRowAction: Equatable {
    /// Tap requests the permission (may prompt — the CALLER's job to mark `// prompt-ok:`).
    case allow
    /// A switch the app owns (launch at login): no system prompt behind it.
    case turnOn
    /// Tap opens the named System Settings pane.
    case openSystemSettings(pane: String)
    /// Tap opens an external URL (Shortcuts.app) — never a system prompt.
    case open(url: String)
    /// Tap switches to the named Settings tab in this same window (Claude access -> MCP).
    case openSettingsTab
    /// Nothing to do: already granted/enabled, or a row with no destination at all
    /// (Spotlight — informational, no app or pane to send anyone to).
    case none
}

/// The panes this window ever sends someone to — the only two panes the app's features need.
enum PermissionsPane {
    static let privacyCalendars = "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
    static let privacyAutomation = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
}

/// Pure decision table. scripts/permissions-selftest.swift compiles THIS file (no mirrored copy).
enum PermissionRowLogic {
    static func action(for status: PermissionStatus, kind: PermissionKind) -> PermissionRowAction {
        switch kind {
        case .calendar, .notes:
            switch status {
            case .granted, .notNeeded: return .none
            case .denied: return .openSystemSettings(pane: kind.settingsPane ?? "")
            case .notDetermined: return .allow
            }
        case .launchAtLogin:
            return status == .granted ? .none : .turnOn   // SMAppService.register(), no system prompt
        case .siriShortcuts:
            // The button opens the Shortcuts app. macOS has no URL scheme to deep-link
            // Shortcuts.app to one app's actions specifically (only `shortcuts://` for the
            // app itself, or `shortcuts://open-shortcut?name=` for one already-built
            // shortcut); Kronos's own actions (Kronos/Intents/**) are real App Intents and DO
            // show up there once opened. `.open` is still the right action, not `.none`.
            return .open(url: "shortcuts://")
        case .spotlight:
            return .none                                   // nothing to grant, nothing to open
        case .claudeAccess:
            return .openSettingsTab
        }
    }
}

/// Every row this window can show. `hasSystemPrompt` = a real macOS permission with a
/// grant/deny state; everything else is informational (no permission to hold).
enum PermissionKind: String, CaseIterable, Identifiable {
    case calendar
    case notes
    case launchAtLogin
    case siriShortcuts
    case spotlight
    case claudeAccess

    var id: String { rawValue }

    var settingsPane: String? {
        switch self {
        case .calendar: return PermissionsPane.privacyCalendars
        case .notes: return PermissionsPane.privacyAutomation
        default: return nil
        }
    }

    var icon: String {
        switch self {
        case .calendar: return "calendar"
        case .notes: return "receipt"
        case .launchAtLogin: return "play"
        case .siriShortcuts: return "sparkles"
        case .spotlight: return "search"
        case .claudeAccess: return "server"
        }
    }

    var titleKey: String {
        switch self {
        case .calendar: return "permissions.row.calendar.title"
        case .notes: return "permissions.row.notes.title"
        case .launchAtLogin: return "permissions.row.launch.title"
        case .siriShortcuts: return "permissions.row.siri.title"
        case .spotlight: return "permissions.row.spotlight.title"
        case .claudeAccess: return "permissions.row.claude.title"
        }
    }

    var reasonKey: String {
        switch self {
        case .calendar: return "permissions.row.calendar.reason"
        case .notes: return "permissions.row.notes.reason"
        case .launchAtLogin: return "permissions.row.launch.reason"
        case .siriShortcuts: return "permissions.row.siri.reason"
        case .spotlight: return "permissions.row.spotlight.reason"
        case .claudeAccess: return "permissions.row.claude.reason"
        }
    }
}
