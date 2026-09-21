// Kronos/Shared/KPlural.swift
// Croatian needs THREE plural categories (one/few/other — CLDR calls the third bucket "other";
// this file calls it "many" to avoid colliding with Swift's own `case other` reads-like-a-typo
// worry, same bucket either way). English needs two. No app string helper anywhere in this
// codebase (`String(format:)` against a plain pattern) can carry three %lld slots in one string
// — that produced a real, user-visible bug (CaptureReviewList.swift read uninitialized
// varargs for the missing 2nd/3rd %lld and printed a garbage number). This picks ONE
// already-correct string with exactly one %lld, per the CLDR-hr rule, and formats it.
//
// PRECISE rule, measured directly (an earlier version of this comment overstated it): a
// LITERAL `String(localized: "key")` against an `.xcstrings` `variations` entry resolves
// correctly, `String(format: String(localized:), locale:, n)` included. What breaks is
// building the KEY STRING at runtime, e.g. `String.LocalizationValue("\(key).\(suffix)")` —
// that produced another real, user-visible bug (gate-shots' snapshot harness printed the raw
// un-resolved key text, "capture.review.count.tasks.many", instead of the localised string)
// because a dynamically built key is never statically visible to Xcode's string-extraction
// tooling the way a literal `String(localized: "literal")` call is — NEVER build a key with
// `\(...)` interpolation.
// This file's own design still avoids `.xcstrings` `variations` entirely (three orphaned
// entries exist — undo.deleted.count, triage.badge.n, error.area.hasprojects.count — but only
// the last has ever had a live call site, and even that one is unreached from any UI): the
// CALL SITE passes three literal `String(localized: "key.one")` / `.few` / `.many` results in;
// this file only picks which one to format, never builds a key string itself. Not because
// `variations` cannot resolve — it can — but because a caller needing three separate flat keys
// already has them as three ordinary literals, so there is no reason to also carry a
// `variations` entry for the same fact.
import Foundation

enum KPlural {
    /// Formats `n` against whichever of the three literal patterns matches its CLDR-hr category.
    /// Each pattern must hold exactly one %lld. Call site example (CaptureReviewList.swift):
    /// ```swift
    /// KPlural.hr(n, one: String(localized: "x.one"), few: String(localized: "x.few"),
    ///            many: String(localized: "x.many"))
    /// ```
    static func hr(_ n: Int, one: String, few: String, many: String) -> String {
        let isCroatian = KronosLocale.languageCode == "hr"
        let pattern: String
        switch KPluralCategory.category(for: n, isCroatian: isCroatian) {
        case .one: pattern = one
        case .few: pattern = few
        case .many: pattern = many
        }
        return String(format: pattern, n)
    }
}
