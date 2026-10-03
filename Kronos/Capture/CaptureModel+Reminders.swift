// Kronos/Capture/CaptureModel+Reminders.swift
// The "From Reminders" tap: ask for access if it was never asked, read the open reminders of
// every list, drop the ones that already became a task, hand the rest to `showReminders` (the
// same review step as pasted text). Denied access and an empty result each end in one calm state
// on the paste step, never a dead button.
//
// Tasks made from reminders carry `source = "reminders"` and `externalID = "reminders:<id>"`, so a
// second import offers nothing twice. Each review row keeps the reminder it was read from and
// `CaptureModel.create()` stamps the task made from that row, so a title edited in review keeps
// its origin too. When Capture's create step finishes (`step` reaches `.done`) the import
// completes exactly those reminders in Reminders, if that option is on.
import Foundation
import KronosCore

/// Where the import reads the store and the "mark complete" option from; replaceable for tests.
@MainActor
enum RemindersImport {
    static let markCompleteKey = "kronos.reminders.markComplete"
    static var store: () -> TaskStore? = { AppDelegate.shared?.store }
    /// Set by an import that found reminders but all of them already known (feedback line).
    static var lastImportAllKnown = false

    static var markComplete: Bool {
        get { KronosEnv.defaults.bool(forKey: markCompleteKey) }
        set { KronosEnv.defaults.set(newValue, forKey: markCompleteKey) }
    }

    /// `externalID` of every task that came from a reminder, completed ones included.
    static func knownExternalIDs(in store: TaskStore) -> Set<String> {
        Set(store.allTasksIncludingSubtasks().compactMap { task in
            task.source == RemindersMapping.originSource ? task.externalID : nil
        })
    }
}

extension CaptureModel {
    func importFromReminders() async {
        guard remindersState != .reading else { return }
        remindersState = .reading
        RemindersImport.lastImportAllKnown = false
        var access = remindersProvider.access
        if access == .notDetermined { access = await remindersProvider.requestAccess() }
        guard access == .granted else { remindersState = .denied; return }
        let all = await remindersProvider.openReminders()
        let known = RemindersImport.store().map(RemindersImport.knownExternalIDs) ?? []
        let items = RemindersMapping.fresh(all, knownExternalIDs: known)
        guard !RemindersMapping.ordered(items).isEmpty else {
            RemindersImport.lastImportAllKnown = !RemindersMapping.ordered(all).isEmpty
            remindersState = .empty
            return
        }
        remindersState = .idle
        showReminders(items)
        watchCreate(of: items, startedAt: Date().addingTimeInterval(-1))
    }

    /// Waits for the create step: when `step` becomes `.done`, stamps the new tasks and, if the
    /// option is on, completes their reminders. Going back to the paste step ends the watch.
    private func watchCreate(of items: [ReminderItem], startedAt: Date) {
        withObservationTracking {
            _ = self.step
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                switch self.step {
                case .done: await self.finishReminderImport(items: items, startedAt: startedAt)
                case .review: self.watchCreate(of: items, startedAt: startedAt)
                case .paste: break
                }
            }
        }
    }

    private func finishReminderImport(items: [ReminderItem], startedAt: Date) async {
        let matched = createdReminders
        guard RemindersImport.markComplete, !matched.isEmpty else { return }
        _ = await remindersProvider.markComplete(identifiers: matched.map(\.id))
    }
}
