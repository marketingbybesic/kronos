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
    static func setEnabled(_ on: Bool, env: [String: String] = ProcessInfo.processInfo.environment) {
        // A scratch run (live test, snapshot, hand test) never registers a login item.
        guard !LaunchKind.isHermetic(env: env), isRunningFromApplications else { return }
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            // Calm failure: the caller re-reads `currentStatus()` and the UI reflects reality.
        }
    }
}

/// How this launch started. A login launch stays out of the way: the menu bar item appears, the
/// window does not. Foundation only, so scripts/reminders-selftest.swift compiles the real file.
enum LaunchKind: Equatable {
    case normal, login

    /// Mirrors `KronosEnv.isHermetic` (KronosCore) for callers that cannot import it.
    static func isHermetic(env: [String: String]) -> Bool {
        if env["KRONOS_UITEST"] != nil || env["KRONOS_SNAPSHOT"] != nil { return true }
        return !(env["KRONOS_STORE_DIR"] ?? "").isEmpty
    }

    /// A hermetic run is never a login launch, whatever the event says.
    static func detect(launchedAsLoginItem: Bool, isHermetic: Bool) -> LaunchKind {
        isHermetic ? .normal : (launchedAsLoginItem ? .login : .normal)
    }

    /// True for the "open application" Apple event the system sends to a login item
    /// (`keyAEPropData` = `keyAELaunchedAsLogInItem`).
    static func isLoginItemEvent(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event, event.eventID == AEEventID(kAEOpenApplication),
              let prop = event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData)) else { return false }
        return prop.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }

    static func currentEventIsLoginItem() -> Bool {
        isLoginItemEvent(NSAppleEventManager.shared().currentAppleEvent)
    }
}
