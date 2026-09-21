// `KTask.recurrenceRule: String?` (Contracts.swift) holds the wire format
// this file defines. `RecurrenceEngine.swift` computes the next `dueDay`
// from it; `RecurrenceSpawner.swift` creates the next instance on
// completion. Nothing here touches SwiftData or `Date` arithmetic — every
// date is a `dueDay: Int` (days since 1970-01-01, local calendar).

import Foundation

/// When a fixed-schedule rule (`daily`/`weekly`/`monthly`/`yearly`) anchors
/// its "after" comparison: the task's own due day, or the day it was
/// actually completed. Ignored by `everyNDays`, which always counts from
/// completion.
public enum RecurrenceAnchor: String, Codable, Equatable, Sendable {
    case fromDueDay
    case fromCompletionDay
}

/// A repeating schedule for a `KTask`. Pure value type: no dates, no
/// calendar, no store access. `RecurrenceEngine` turns one of these plus a
/// `dueDay`/`completedOn` pair into the next `dueDay`.
///
/// Wire format (what lives in `KTask.recurrenceRule`): compact, versioned,
/// human-legible text — not the embedded-JSON `KRecurrence` shape once
/// sketched for export, which this leaf does not implement (out of scope:
/// no export/import writer was named in this ledger). Grammar:
///
/// ```
/// v1;daily;<every>;anchor=<due|completion>
/// v1;weekly;<every>;days=<iso1,iso2,...>;anchor=<due|completion>
/// v1;monthly;<every>;day=<1-31>;anchor=<due|completion>
/// v1;yearly;month=<1-12>;day=<1-31>;anchor=<due|completion>
/// v1;everyNDays;<n>
/// ```
///
/// `everyNDays` has no `anchor` field: it is always "N days after the day I
/// actually completed it" (D21's "N days after completion" case), so there
/// is nothing to disambiguate. Field order is fixed; `parse` rejects any
/// other order or an unknown key. A future `v2` gets its own case in
/// `parse` — old rows keep parsing under `v1` rules forever.
public enum RecurrenceRule: Codable, Equatable, Sendable {
    /// Every `every` days (`every >= 1`).
    case daily(every: Int, anchor: RecurrenceAnchor)
    /// Every `every` weeks, firing on each weekday in `weekdays`
    /// (ISO numbering, 1 = Monday … 7 = Sunday; non-empty).
    case weekly(every: Int, weekdays: Set<Int>, anchor: RecurrenceAnchor)
    /// Every `every` months, on `day` (1…31, clamped to the month's last day).
    case monthly(every: Int, day: Int, anchor: RecurrenceAnchor)
    /// Once a year on `month`/`day` (29 Feb clamps to 28 Feb in non-leap years).
    case yearly(month: Int, day: Int, anchor: RecurrenceAnchor)
    /// `days` days after the day the task was actually completed. The
    /// "every N days after I did it" case — always completion-anchored.
    case everyNDays(Int)

    /// The anchor mode this rule uses. `everyNDays` reports
    /// `.fromCompletionDay` since that is its only behaviour.
    public var anchor: RecurrenceAnchor {
        switch self {
        case .daily(_, let a), .weekly(_, _, let a), .monthly(_, _, let a), .yearly(_, _, let a):
            return a
        case .everyNDays:
            return .fromCompletionDay
        }
    }

    // MARK: - Wire format

    /// Serializes to the `v1;...` string stored in `KTask.recurrenceRule`.
    public var wireFormat: String {
        func a(_ x: RecurrenceAnchor) -> String { x == .fromDueDay ? "due" : "completion" }
        switch self {
        case .daily(let every, let anchor):
            return "v1;daily;\(every);anchor=\(a(anchor))"
        case .weekly(let every, let weekdays, let anchor):
            let days = weekdays.sorted().map(String.init).joined(separator: ",")
            return "v1;weekly;\(every);days=\(days);anchor=\(a(anchor))"
        case .monthly(let every, let day, let anchor):
            return "v1;monthly;\(every);day=\(day);anchor=\(a(anchor))"
        case .yearly(let month, let day, let anchor):
            return "v1;yearly;month=\(month);day=\(day);anchor=\(a(anchor))"
        case .everyNDays(let days):
            return "v1;everyNDays;\(days)"
        }
    }

    /// Strict parse: malformed, out-of-range, or unknown-version input
    /// returns nil rather than guessing (data-model §6.1's import rule,
    /// applied here to the string wire format instead of the JSON one).
    public static func parse(_ s: String) -> RecurrenceRule? {
        let parts = s.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts[0] == "v1" else { return nil }
        let kind = parts[1]

        func intField(_ raw: String) -> Int? { Int(raw) }
        func kv(_ raw: String) -> (String, String)? {
            guard let eq = raw.firstIndex(of: "=") else { return nil }
            return (String(raw[raw.startIndex..<eq]), String(raw[raw.index(after: eq)...]))
        }
        func anchor(from raw: String) -> RecurrenceAnchor? {
            guard let (key, value) = kv(raw), key == "anchor" else { return nil }
            switch value {
            case "due": return .fromDueDay
            case "completion": return .fromCompletionDay
            default: return nil
            }
        }

        switch kind {
        case "daily":
            guard parts.count == 4, let every = intField(parts[2]), every >= 1,
                  let anc = anchor(from: parts[3]) else { return nil }
            return .daily(every: every, anchor: anc)

        case "weekly":
            guard parts.count == 5, let every = intField(parts[2]), every >= 1,
                  let (daysKey, daysValue) = kv(parts[3]), daysKey == "days",
                  let anc = anchor(from: parts[4]) else { return nil }
            let days = daysValue.split(separator: ",").compactMap { Int($0) }
            guard !days.isEmpty, days.allSatisfy({ (1...7).contains($0) }) else { return nil }
            return .weekly(every: every, weekdays: Set(days), anchor: anc)

        case "monthly":
            guard parts.count == 5, let every = intField(parts[2]), every >= 1,
                  let (dayKey, dayValue) = kv(parts[3]), dayKey == "day",
                  let day = Int(dayValue), (1...31).contains(day),
                  let anc = anchor(from: parts[4]) else { return nil }
            return .monthly(every: every, day: day, anchor: anc)

        case "yearly":
            guard parts.count == 5,
                  let (monthKey, monthValue) = kv(parts[2]), monthKey == "month",
                  let month = Int(monthValue), (1...12).contains(month),
                  let (dayKey, dayValue) = kv(parts[3]), dayKey == "day",
                  let day = Int(dayValue), (1...31).contains(day),
                  let anc = anchor(from: parts[4]) else { return nil }
            return .yearly(month: month, day: day, anchor: anc)

        case "everyNDays":
            guard parts.count == 3, let days = intField(parts[2]), days >= 1 else { return nil }
            return .everyNDays(days)

        default:
            return nil
        }
    }

    // MARK: - Codable (via the wire string, so JSON export round-trips too)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        guard let rule = RecurrenceRule.parse(s) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad recurrence wire format: \(s)")
        }
        self = rule
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wireFormat)
    }

    // MARK: - Human-legible description

    private static let hrWeekdayAbbrev = ["pon", "uto", "sri", "čet", "pet", "sub", "ned"]
    private static let enWeekdayAbbrev = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    private static let hrMonthGenitive = [
        "siječnja", "veljače", "ožujka", "travnja", "svibnja", "lipnja",
        "srpnja", "kolovoza", "rujna", "listopada", "studenog", "prosinca",
    ]
    private static let enMonthName = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]

    private static func ordinalEN(_ n: Int) -> String {
        let suffix: String
        switch (n % 100, n % 10) {
        case (11, _), (12, _), (13, _): suffix = "th"
        case (_, 1): suffix = "st"
        case (_, 2): suffix = "nd"
        case (_, 3): suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }

    /// A short human sentence with no exclamation marks, in `locale`
    /// ("en" or "hr"; anything else falls back to English). Croatian uses
    /// the correct case forms the brief calls out: "Svaki tjedan: pon, sri",
    /// "Svaka 3 dana", "Svakih 5 dana" — Croatian's every-N-days phrase
    /// changes ending by count (2-4 -> "Svaka", 5+ -> "Svakih", 1 handled
    /// by the plain "daily" case).
    public func description(locale: String) -> String {
        let hr = locale.hasPrefix("hr")
        switch self {
        case .daily(let every, _):
            if every == 1 { return hr ? "Svaki dan" : "Every day" }
            return hr ? "\(everyWordHR(every)) dana" : "Every \(every) days"

        case .weekly(let every, let weekdays, _):
            let names = weekdays.sorted().map { hr ? Self.hrWeekdayAbbrev[$0 - 1] : Self.enWeekdayAbbrev[$0 - 1] }
            let list = names.joined(separator: ", ")
            if every == 1 { return hr ? "Svaki tjedan: \(list)" : "Every week: \(list)" }
            return hr ? "\(everyWordHR(every)) tjedna: \(list)" : "Every \(every) weeks: \(list)"

        case .monthly(let every, let day, _):
            if every == 1 { return hr ? "Svaki mjesec \(day)." : "Every month on the \(Self.ordinalEN(day))" }
            return hr ? "\(everyWordHR(every)) mjeseca \(day)." : "Every \(every) months on the \(Self.ordinalEN(day))"

        case .yearly(let month, let day, _):
            return hr
                ? "Svake godine \(day). \(Self.hrMonthGenitive[month - 1])"
                : "Every year on \(Self.enMonthName[month - 1]) \(Self.ordinalEN(day))"

        case .everyNDays(let days):
            if days == 1 { return hr ? "Svaki dan nakon završetka" : "Every day after completion" }
            return hr ? "\(everyWordHR(days)) dana nakon završetka" : "\(days) days after completion"
        }
    }

    /// Croatian "every N" agreement: 1 is handled by callers separately;
    /// 2-4 (excluding 12-14) takes "Svaka", everything else takes "Svakih".
    private func everyWordHR(_ n: Int) -> String {
        let lastTwo = n % 100
        let last = n % 10
        if last >= 2, last <= 4, !(lastTwo >= 12 && lastTwo <= 14) { return "Svaka \(n)" }
        return "Svakih \(n)"
    }
}
