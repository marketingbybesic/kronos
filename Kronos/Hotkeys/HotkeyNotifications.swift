// Kronos/Hotkeys/HotkeyNotifications.swift
// Notification names posted by the two global hotkeys registered in QuickAddController.swift.
// This file only posts them; the menu-bar cockpit and triage observe these EXACT raw strings
// to open meeting capture / show the Ordo popover.
import Foundation

extension Notification.Name {
    /// Posted by the `global.meetingcapture` hotkey (default Ctrl-Opt-M).
    static let kronosMeetingCaptureRequested = Notification.Name("kronosMeetingCaptureRequested")
    /// Posted by the `global.showordo` hotkey (default Ctrl-Opt-O).
    static let kronosShowOrdoRequested = Notification.Name("kronosShowOrdoRequested")
}
