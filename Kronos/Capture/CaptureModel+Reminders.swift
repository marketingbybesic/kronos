// Kronos/Capture/CaptureModel+Reminders.swift
// The "From Reminders" tap: ask for access if it was never asked, read the open reminders of
// every list, hand them to `showReminders` (the same review step as pasted text). Denied access
// and an empty result each end in one calm state on the paste step, never a dead button.
import Foundation

extension CaptureModel {
    func importFromReminders() async {
        guard remindersState != .reading else { return }
        remindersState = .reading
        var access = remindersProvider.access
        if access == .notDetermined { access = await remindersProvider.requestAccess() }
        guard access == .granted else { remindersState = .denied; return }
        let items = await remindersProvider.openReminders()
        guard !RemindersMapping.ordered(items).isEmpty else { remindersState = .empty; return }
        remindersState = .idle
        showReminders(items)
    }
}
