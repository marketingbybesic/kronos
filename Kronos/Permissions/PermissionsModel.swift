// Kronos/Permissions/PermissionsModel.swift
// One classic place for every system permission / system connection Kronos uses, the same
// kind of permissions window other Mac apps offer. This file only reads status and decides
// what a row's button should do — it never triggers a system prompt itself; only
// `PermissionsWindow`'s button taps call the actual request APIs (via
// `model.coach.requestCalendarAccess()` etc).

import Foundation
import AppKit
import Observation
import KronosCore

/// Fixture status provider for snapshots (never real system state — brief's OWNS rule).
/// `@MainActor`: `LivePermissionsStatus` below reads `AppModel`/`model.coach`, both main-actor
/// types, so the protocol itself must be isolated rather than each conformance crossing in.
@MainActor
protocol PermissionsStatusProviding {
    func status(for kind: PermissionKind) -> PermissionStatus
}

/// Fixed statuses for `permissions` / `permissions.mixed` / `permissions.granted` snapshots.
struct FixturePermissionsStatus: PermissionsStatusProviding {
    let statuses: [PermissionKind: PermissionStatus]
    func status(for kind: PermissionKind) -> PermissionStatus {
        statuses[kind] ?? (kind == .siriShortcuts || kind == .spotlight ? .notNeeded : .notDetermined)
    }
}

/// Reads the app's real status for every row. `AppModel`-backed so Calendar reuses
/// `model.coach.calendarAccess` (never a second EventKit read path) and Notes/launch/MCP
/// read their own owning types directly. Never prompts on its own (G5) — `status(for:)`
/// only reads current state.
@MainActor
final class LivePermissionsStatus: PermissionsStatusProviding {
    private unowned let model: AppModel
    private let mcpStatus: MCPStatusProviding

    init(model: AppModel, mcpStatus: MCPStatusProviding) {
        self.model = model
        self.mcpStatus = mcpStatus
    }

    func status(for kind: PermissionKind) -> PermissionStatus {
        switch kind {
        case .calendar:
            switch model.coach.calendarAccess {
            case .granted: return .granted
            case .denied: return .denied
            case .notDetermined: return .notDetermined
            }
        case .notes:
            return NotesPermissionReader.currentStatus()
        case .launchAtLogin:
            return LaunchAtLogin.currentStatus() == .enabled ? .granted : .notDetermined
        case .siriShortcuts, .spotlight:
            return .notNeeded
        case .claudeAccess:
            return mcpStatus.isRunning ? .granted : .notDetermined
        }
    }
}

/// Reads Apple Notes Automation status without ever prompting (G5): asks Apple Events
/// with `askUserIfNeeded` false, exactly like `AEDeterminePermissionToAutomateTarget`'s
/// documented no-prompt mode. Separate from `OsaScriptNotesBridge` (that type actually
/// calls Notes; this only asks the TCC/Apple Events layer whether it may, without doing so).
enum NotesPermissionReader {
    static func currentStatus() -> PermissionStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.Notes")
        let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false) // prompt-ok: askUserIfNeeded=false, read-only status check, never prompts
        switch Int(status) {
        case 0: return .granted            // noErr
        case -1744: return .notDetermined  // errAEEventWouldRequireUserConsent
        default: return .denied            // errAEEventNotPermitted (-1743) and anything else
        }
    }
}
