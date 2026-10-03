// Kronos/List/ListDueText.swift
// The visible date of a task row or child row. No verdict words: an earlier date shows as the
// date it was, muted; today reads "Today"; the next six days read as a weekday ("Fri"); later
// dates read as a short date. The decision itself is `ListDueKind` (ListRules.swift).
import Foundation
import KronosCore

enum ListDueText {
    struct Shown: Equatable {
        let text: String
        let muted: Bool
    }

    static func shown(due: Int, original: Int? = nil, today: Int = Day.today()) -> Shown {
        switch ListDueKind.of(due: due, today: today) {
        case .earlier:
            let day = ListDueKind.shownDay(due: due, original: original, today: today)
            return Shown(text: dateFormatter.string(from: Day.date(day)), muted: true)
        case .today:
            return Shown(text: String(localized: "list.filter.due.today"), muted: false)
        case .weekday:
            return Shown(text: weekdayFormatter.string(from: Day.date(due)), muted: false)
        case .date:
            return Shown(text: dateFormatter.string(from: Day.date(due)), muted: false)
        }
    }

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = KronosLocale.calendar
        f.locale = KronosLocale.current
        f.setLocalizedDateFormatFromTemplate("EEE")
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = KronosLocale.calendar
        f.locale = KronosLocale.current
        f.setLocalizedDateFormatFromTemplate("dMMM")
        return f
    }()
}
