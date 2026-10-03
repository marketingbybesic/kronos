// Kronos/Capture/CaptureDeadlineFormatter.swift
// The short deadline text of a Capture review row ("Oct 4" / "4. lis").
import Foundation
import KronosCore

/// Short month-and-day text in the app language (KronosLocale-aware).
enum CaptureDeadlineFormatter {
    static func short(day: Int) -> String {
        let date = KronosCore.Day.date(day, calendar: KronosLocale.calendar)
        let formatter = DateFormatter()
        formatter.locale = KronosLocale.current
        formatter.calendar = KronosLocale.calendar
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter.string(from: date)
    }
}
