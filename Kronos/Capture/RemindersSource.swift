// Kronos/Capture/RemindersSource.swift
// Access to the open reminders of every Reminders list, through EventKit. Reading never changes
// anything: Capture proposes tasks, the user ticks them, Reminders stays untouched. The one write is
// the optional "also mark them complete in Reminders" (off by default, `markComplete`), run only
// for reminders whose task was just created.
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
    /// Completes the reminders with these identifiers; returns how many were completed. Only called
    /// after the person turned the option on and the matching tasks were created.
    func markComplete(identifiers: [String]) async -> Int
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
                                 listName: r.calendar?.title ?? "", id: r.calendarItemIdentifier)
                }
                continuation.resume(returning: items)
            }
        }
    }
}

extension EventKitReminders {
    func markComplete(identifiers: [String]) async -> Int {
        guard access == .granted else { return 0 }
        var done = 0
        for id in identifiers {
            guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder, !reminder.isCompleted else { continue }
            reminder.isCompleted = true
            if (try? store.save(reminder, commit: false)) != nil { done += 1 }
        }
        if done > 0 { try? store.commit() }
        return done
    }
}

/// Fixed answer for snapshots and tests: never touches EventKit.
@MainActor
struct FixtureReminders: RemindersProviding {
    var access: RemindersAccess = .granted
    var items: [ReminderItem] = []
    func requestAccess() async -> RemindersAccess { access }
    func openReminders() async -> [ReminderItem] { items }
    func markComplete(identifiers: [String]) async -> Int { 0 }
}

/// Test double that remembers what it was asked to complete.
@MainActor
final class RecordingReminders: RemindersProviding {
    var access: RemindersAccess = .granted
    var items: [ReminderItem]
    private(set) var completed: [String] = []
    init(items: [ReminderItem]) { self.items = items }
    func requestAccess() async -> RemindersAccess { access }
    func openReminders() async -> [ReminderItem] { items }
    func markComplete(identifiers: [String]) async -> Int {
        completed += identifiers
        return identifiers.count
    }
}
