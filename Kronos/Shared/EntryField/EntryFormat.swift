// Kronos/Shared/EntryField/EntryFormat.swift
// Display strings of the entry field's pills and suggestions. Every string is a literal
// catalog key (no runtime-built keys, which would print raw), localised in the APP language.
import Foundation
import KronosCore

enum EntryFormat {

    static func priorityName(_ p: KPriority) -> String {
        switch p {
        case .none: return String(localized: "priority.none")
        case .low: return String(localized: "priority.low")
        case .medium: return String(localized: "priority.medium")
        case .high: return String(localized: "priority.high")
        case .urgent: return String(localized: "priority.urgent")
        }
    }

    static func effortName(_ e: KEffort) -> String {
        switch e {
        case .none: return String(localized: "effort.none")
        case .xs: return String(localized: "effort.xs")
        case .s: return String(localized: "effort.s")
        case .m: return String(localized: "effort.m")
        case .l: return String(localized: "effort.l")
        case .xl: return String(localized: "effort.xl")
        }
    }

    /// Today / Tomorrow / weekday name / "20 Sep". `RelativeDateTimeFormatter` and
    /// `DateFormatter` are built with the APP language (`KronosLocale.current`), never the
    /// system locale, so Croatian shows "Sutra" regardless of macOS settings.
    static func relativeDay(_ day: Int) -> String {
        let calendar = KronosLocale.calendar
        let today = Day.today(calendar: calendar)
        let date = Day.date(day, calendar: calendar)
        if day == today { return String(localized: "list.filter.due.today") }
        if day == today + 1 {
            let formatter = RelativeDateTimeFormatter()
            formatter.calendar = calendar
            formatter.locale = KronosLocale.current
            formatter.dateTimeStyle = .named
            formatter.formattingContext = .beginningOfSentence
            return formatter.localizedString(for: date, relativeTo: Day.date(today, calendar: calendar))
        }
        if day > today, day - today < 7 {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = KronosLocale.current
            formatter.setLocalizedDateFormatFromTemplate("EEEE")
            return formatter.string(from: date)
        }
        return shortDate(day)
    }

    /// "20 Sep" (weekday-less), the second line of a date suggestion.
    static func shortDate(_ day: Int) -> String {
        let calendar = KronosLocale.calendar
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = KronosLocale.current
        formatter.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return formatter.string(from: Day.date(day, calendar: calendar))
    }

    /// The pill's text.
    static func pillText(_ pill: EntryPill) -> String {
        switch pill {
        case .destination(let d):
            if d.isNew { return String(format: String(localized: "quickadd.entry.pill.newproject"), d.name) }
            switch d.kind {
            case .project: return String(format: String(localized: "quickadd.chip.project"), d.name)
            case .area: return String(format: String(localized: "quickadd.entry.pill.area"), d.name)
            }
        case .label(let n): return String(format: String(localized: "quickadd.chip.label"), n)
        case .priority(let p): return String(format: String(localized: "quickadd.chip.priority"), priorityName(p))
        case .effort(let e): return String(format: String(localized: "quickadd.chip.effort.value"), effortName(e))
        case .due(let day): return String(format: String(localized: "quickadd.chip.due"), relativeDay(day))
        case .repeats(let r): return repeatName(r)
        }
    }

    /// "Every week" / "Svaki tjedan", "Every 2 weeks" / "Svaka 2 tjedna", "Every Monday" /
    /// "Svaki ponedjeljak". Literal keys only; Croatian counts take one/few/many forms.
    static func repeatName(_ r: RepeatPhrase) -> String {
        if let weekday = r.weekday, r.unit == .week, r.every == 1 {
            switch weekday {
            case 1: return String(localized: "quickadd.repeat.weekday.mon")
            case 2: return String(localized: "quickadd.repeat.weekday.tue")
            case 3: return String(localized: "quickadd.repeat.weekday.wed")
            case 4: return String(localized: "quickadd.repeat.weekday.thu")
            case 5: return String(localized: "quickadd.repeat.weekday.fri")
            case 6: return String(localized: "quickadd.repeat.weekday.sat")
            default: return String(localized: "quickadd.repeat.weekday.sun")
            }
        }
        if r.every == 1 {
            switch r.unit {
            case .day: return String(localized: "quickadd.repeat.day")
            case .week: return String(localized: "quickadd.repeat.week")
            case .month: return String(localized: "quickadd.repeat.month")
            }
        }
        let category = KPluralCategory.category(for: r.every, isCroatian: KronosLocale.languageCode == "hr")
        let pattern: String
        switch (r.unit, category) {
        case (.day, .one): pattern = String(localized: "quickadd.repeat.days.one")
        case (.day, .few): pattern = String(localized: "quickadd.repeat.days.few")
        case (.day, .many): pattern = String(localized: "quickadd.repeat.days.many")
        case (.week, .one): pattern = String(localized: "quickadd.repeat.weeks.one")
        case (.week, .few): pattern = String(localized: "quickadd.repeat.weeks.few")
        case (.week, .many): pattern = String(localized: "quickadd.repeat.weeks.many")
        case (.month, .one): pattern = String(localized: "quickadd.repeat.months.one")
        case (.month, .few): pattern = String(localized: "quickadd.repeat.months.few")
        case (.month, .many): pattern = String(localized: "quickadd.repeat.months.many")
        }
        return String(format: pattern, r.every)
    }

    /// Accessibility name of a slot, for the "change" action of a pill.
    static func slotName(_ slot: EntryPill.Slot) -> String {
        switch slot {
        case .destination: return String(localized: "quickadd.entry.slot.destination")
        case .label: return String(localized: "quickadd.entry.slot.label")
        case .priority: return String(localized: "quickadd.entry.slot.priority")
        case .effort: return String(localized: "quickadd.entry.slot.effort")
        case .due: return String(localized: "quickadd.entry.slot.due")
        case .repeats: return String(localized: "quickadd.entry.slot.repeat")
        }
    }
}
