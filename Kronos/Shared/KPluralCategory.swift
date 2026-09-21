// Kronos/Shared/KPluralCategory.swift. Foundation-only pure function, hand-tested by
// scripts/plural-selftest.swift against this exact file compiled standalone (no KronosLocale, no
// KronosCore — same shape as Kronos/TimeBlocks/TimeBlockSelection.swift). `KPlural.swift` is the
// thin wrapper that calls this with `KronosLocale.languageCode` and formats the chosen string.
import Foundation

enum KPluralCategory {
    enum Category { case one, few, many }

    /// CLDR rule for Croatian integers:
    /// one: n%10==1 && n%100!=11 · few: n%10 in 2...4 && n%100 not in 12...14 · else many.
    /// Trap: 0 is `.many` in Croatian ("0 zadataka"), and 11-14 are `.many` despite 1-4 being
    /// one/few. English only ever needs `.one` (n == 1) vs `.many` (everything else) — English
    /// has no "few" form, so it is never returned when `isCroatian` is false.
    static func category(for n: Int, isCroatian: Bool) -> Category {
        let i = abs(n)
        guard isCroatian else { return i == 1 ? .one : .many }
        if i % 10 == 1 && i % 100 != 11 { return .one }
        if (2...4).contains(i % 10) && !(12...14).contains(i % 100) { return .few }
        return .many
    }
}
