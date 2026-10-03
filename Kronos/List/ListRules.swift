// Kronos/List/ListRules.swift
// Small list decisions made from plain numbers, kept free of SwiftUI and KronosCore so
// scripts/bulk-selftest.swift can compile this file on its own against hand-written tables.
import Foundation

/// How a row's date reads, decided from day numbers alone. There is no "overdue" verdict: a date
/// before today shows as the date it was, muted; the next six days show their weekday.
enum ListDueKind: Equatable {
    /// Before today: the original date, muted.
    case earlier
    case today
    /// One to `weekdayHorizon` days ahead: the short weekday name ("Fri").
    case weekday
    /// Further ahead: the short date.
    case date

    static let weekdayHorizon = 6

    static func of(due: Int, today: Int) -> ListDueKind {
        let delta = due - today
        if delta < 0 { return .earlier }
        if delta == 0 { return .today }
        return delta <= weekdayHorizon ? .weekday : .date
    }

    /// The day a muted earlier date shows: the first deadline the task had when the night sweep
    /// recorded one, otherwise the deadline itself. A later deadline is never replaced by it.
    static func shownDay(due: Int, original: Int?, today: Int) -> Int {
        guard of(due: due, today: today) == .earlier, let original, original <= due else { return due }
        return original
    }
}

/// The day-clear cue: it plays once, when Today goes from showing rows to showing none and
/// something was finished today. The first look at a list (launch, switching to Today) is never
/// a transition, so an already empty Today stays silent.
enum DayClearCue {
    static func shouldPlay(previousRows: Int?, nowRows: Int, doneToday: Int) -> Bool {
        guard let previousRows else { return false }
        return previousRows > 0 && nowRows == 0 && doneToday > 0
    }
}

/// Which completion cue a finished task earns: a parent that has children gets the parent cue.
enum CompletionCueRule {
    static func isParentFinish(childCount: Int) -> Bool { childCount > 0 }
}
