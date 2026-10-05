// Kronos/Capture/RemindersSource.swift
// The Reminders permission, through EventKit: what the Permissions window shows and its Allow
// button. Capture no longer reads reminders; only the permission row remains.
//
// Authorisation uses only `requestFullAccessToReminders()` (macOS 14+; the old
// `requestAccess(to:)` silently denies). It is called from one place, the Permissions window's
// Allow button; reading the status never prompts. Needs `NSRemindersFullAccessUsageDescription`
// in Info.plist.
import EventKit
import Foundation

enum RemindersAccess: Equatable {
    case granted
    case notDetermined
    case denied
}

@MainActor
final class EventKitReminders {
    static let shared = EventKitReminders()
    private let store = EKEventStore()

    static func currentAccess() -> RemindersAccess {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied // .denied, .restricted, .writeOnly and any future case
        }
    }

    /// The status the Permissions window shows. Never prompts.
    static func permissionStatus() -> PermissionStatus {
        switch currentAccess() {
        case .granted: return .granted
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        }
    }

    var access: RemindersAccess { Self.currentAccess() }

    func requestAccess() async -> RemindersAccess {
        if access != .notDetermined { return access }
        do {
            let granted = try await store.requestFullAccessToReminders() // prompt-ok: only runs from an explicit tap
            return granted ? .granted : .denied
        } catch {
            return .denied
        }
    }
}
