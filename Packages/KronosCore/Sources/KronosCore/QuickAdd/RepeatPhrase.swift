import Foundation

/// "every week" / "svaki tjedan" typed in an entry field: a repeating schedule read from words,
/// shown as a pill and turned into a `RecurrenceRule` when the task is created.
///
/// The phrase keeps only what was typed (how often, which unit, an optional weekday). The rule
/// itself also needs the task's first due day (a weekly rule fires on a weekday, a monthly rule
/// on a day of the month), and that day can come from a date typed in the same line, so the rule
/// is built at create time by `rule(firstDue:calendar:)`. A phrase with no typed date starts on
/// `firstDue(today:calendar:)`: today, or the next named weekday.
///
/// Grammar (English and Croatian, any case, with or without diacritics):
///   every [N | number word | other] day(s) | week(s) | month(s)
///   every <weekday>
///   svaki | svaku | svake | svakog | svaka | svakih [N | number word] dan(a) | tjedan(a) | mjesec(a)
///   svaki ponedjeljak | svaku srijedu | svake subote ...
public struct RepeatPhrase: Hashable, Sendable {
    public enum Unit: String, Sendable { case day, week, month }

    /// How many units between two occurrences, 1...99.
    public var every: Int
    public var unit: Unit
    /// ISO weekday (1 = Monday ... 7 = Sunday) of an "every Monday" phrase; always with `.week`.
    public var weekday: Int?

    public init(every: Int = 1, unit: Unit, weekday: Int? = nil) {
        self.every = every
        self.unit = unit
        self.weekday = weekday
    }

    /// The rule stored on the task, anchored on its first due day. Fixed schedule
    /// (`fromDueDay`): "every Monday" stays on Mondays even when one is done late.
    public func rule(firstDue: Int, calendar: Calendar) -> RecurrenceRule {
        switch unit {
        case .day:
            return .daily(every: every, anchor: .fromDueDay)
        case .week:
            return .weekly(every: every, weekdays: [weekday ?? Self.isoWeekday(firstDue, calendar: calendar)],
                           anchor: .fromDueDay)
        case .month:
            let day = calendar.component(.day, from: Day.date(firstDue, calendar: calendar))
            return .monthly(every: every, day: day, anchor: .fromDueDay)
        }
    }

    /// The first due day when the line names no date: the next `weekday` on or after today
    /// ("every Monday" typed on a Monday starts today), otherwise today.
    public func firstDue(today: Int, calendar: Calendar) -> Int {
        guard let weekday else { return today }
        let current = Self.isoWeekday(today, calendar: calendar)
        return today + (weekday - current + 7) % 7
    }

    static func isoWeekday(_ day: Int, calendar: Calendar) -> Int {
        let sunday1 = calendar.component(.weekday, from: Day.date(day, calendar: calendar))
        return sunday1 == 1 ? 7 : sunday1 - 1
    }

    // MARK: Reading words

    /// Lead words, folded (lowercase, no diacritics).
    static let englishLead: Set<String> = ["every"]
    static let croatianLead: Set<String> = ["svaki", "svaku", "svake", "svakog", "svakoga", "svaka", "svakih"]

    /// Units, folded. Croatian keeps the case forms a count or "svaki" takes.
    static let units: [String: Unit] = [
        "day": .day, "days": .day, "dan": .day, "dana": .day,
        "week": .week, "weeks": .week, "tjedan": .week, "tjedna": .week, "tjedana": .week,
        "month": .month, "months": .month, "mjesec": .month, "mjeseca": .month, "mjeseci": .month,
    ]

    /// Weekdays, folded, in the forms that follow "every" / "svaki" (nominative, accusative,
    /// genitive). The bare 3-letter Croatian abbreviations are left out on purpose, as in
    /// `QuickAddParser.weekdayNames` ("pet" is also "five").
    static let weekdays: [String: Int] = [
        "monday": 1, "mon": 1, "ponedjeljak": 1, "ponedjeljka": 1,
        "tuesday": 2, "tue": 2, "utorak": 2, "utorka": 2,
        "wednesday": 3, "wed": 3, "srijeda": 3, "srijedu": 3, "srijede": 3,
        "thursday": 4, "thu": 4, "cetvrtak": 4, "cetvrtka": 4,
        "friday": 5, "fri": 5, "petak": 5, "petka": 5,
        "saturday": 6, "sat": 6, "subota": 6, "subotu": 6, "subote": 6,
        "sunday": 7, "sun": 7, "nedjelja": 7, "nedjelju": 7, "nedjelje": 7,
    ]

    /// Reads a phrase starting at `words[0]`. Returns the phrase and how many words it spans
    /// (2 or 3), or nil when the words are not a repeat phrase.
    public static func match(_ words: [String]) -> (phrase: RepeatPhrase, span: Int)? {
        guard let lead = words.first.map(KTextFold.fold),
              englishLead.contains(lead) || croatianLead.contains(lead), words.count >= 2 else { return nil }
        let second = KTextFold.fold(words[1])
        if let unit = units[second] { return (RepeatPhrase(unit: unit), 2) }
        if let weekday = weekdays[second] { return (RepeatPhrase(unit: .week, weekday: weekday), 2) }
        guard words.count >= 3, let unit = units[KTextFold.fold(words[2])] else { return nil }
        let count: Int?
        if second == "other", englishLead.contains(lead) {
            count = 2
        } else {
            count = Int(second) ?? DatePhrases.resolveNumberWord(second)
        }
        guard let n = count, (1...99).contains(n) else { return nil }
        return (RepeatPhrase(every: n, unit: unit), 3)
    }
}
