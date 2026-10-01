// Kronos/Capture/RemindersSource.swift
// Read-only access to the open reminders of every Reminders list, through EventKit. Nothing is
// ever written back: Capture proposes tasks, the user ticks them, Reminders stays untouched.
//
// Authorisation uses only `requestFullAccessToReminders()` (macOS 14+; the old
// `requestAccess(to:)` silently denies). It is called from one place, the explicit "From
// Reminders" tap or the Permissions window's Allow button; reading the status never prompts.
// Needs `NSRemindersFullAccessUsageDescription` in Info.plist (project.yml is leaf f's: see the
// report's NEEDS FROM DRIVER).
import EventKit
import Foundation

enum RemindersAccess: Equatable {
    case granted
    case notDetermined
    case denied
}

@MainActor
protocol RemindersProviding {
    var access: RemindersAccess { get }
    func requestAccess() async -> RemindersAccess
    func openReminders() async -> [ReminderItem]
}

@MainActor
final class EventKitReminders: RemindersProviding {
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

    /// Every INCOMPLETE reminder of every list, as plain values (EKReminder is not Sendable, so
    /// it is mapped inside the fetch callback and never leaves it).
    func openReminders() async -> [ReminderItem] {
        guard access == .granted else { return [] }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let calendar = Calendar.current
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let items = (reminders ?? []).map { r in
                    ReminderItem(title: r.title ?? "", notes: r.notes,
                                 due: r.dueDateComponents.flatMap { calendar.date(from: $0) },
                                 listName: r.calendar?.title ?? "")
                }
                continuation.resume(returning: items)
            }
        }
    }
}

/// Fixed answer for snapshots and tests: never touches EventKit.
@MainActor
struct FixtureReminders: RemindersProviding {
    var access: RemindersAccess = .granted
    var items: [ReminderItem] = []
    func requestAccess() async -> RemindersAccess { access }
    func openReminders() async -> [ReminderItem] { items }
}
