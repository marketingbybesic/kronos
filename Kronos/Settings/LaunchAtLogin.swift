// Kronos/Settings/LaunchAtLogin.swift
// SMAppService wrapper. Only works from /Applications; Settings
// reads `.status` live rather than trusting its own stored boolean, because the user can
// revoke the item in System Settings -> General -> Login Items.

import Foundation
import ServiceManagement

enum SMAppServiceStatus: Equatable {
    case notRegistered, enabled, requiresApproval, notFound
}

enum LaunchAtLogin {
    static var isRunningFromApplications: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }

    static func currentStatus() -> SMAppServiceStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .notRegistered
        }
    }

    /// Best-effort: a failure (e.g. not in /Applications) leaves the toggle where it was —
    /// the row's disabled state plus the inline note is the only feedback, never an alert.
    static func setEnabled(_ on: Bool) {
        guard isRunningFromApplications else { return }
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            // Calm failure: the caller re-reads `currentStatus()` and the UI reflects reality.
        }
    }
}
