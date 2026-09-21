// APP LANGUAGE. One source of truth for the language Kronos speaks, so dates, relative times
// and plurals follow the APP language rather than the system locale (a real bug: the
// inspector showed "9/15" on a Mac set to Croatian, an American date format on a
// Croatian-speaking system).
//
// Settings writes `KronosLocale.preference`; every formatter in the app must be built with
// `KronosLocale.current` — never `Locale.current`, never a formatter without a locale.

import Foundation

enum KronosLocale {
    enum Preference: String, CaseIterable, Sendable { case system, en, hr }

    private static let key = "kronos.language"

    /// The user's choice. `.system` follows macOS: Croatian if the system prefers it, else English.
    static var preference: Preference {
        get { Preference(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            // String(localized:) resolves through the bundle's preferred localizations, which
            // AppKit fixes at launch; Settings tells the user a restart applies it everywhere.
            switch newValue {
            case .system: UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            case .en: UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
            case .hr: UserDefaults.standard.set(["hr"], forKey: "AppleLanguages")
            }
        }
    }

    /// "en" or "hr" — the two languages Kronos ships.
    static var languageCode: String {
        switch preference {
        case .en: return "en"
        case .hr: return "hr"
        case .system: return resolveSystem(Locale.preferredLanguages)
        }
    }

    /// `.system`'s pure resolution rule: the FIRST entry in the ranked preference list that
    /// Kronos ships (en, hr) wins, not just the very first entry in the list — a Mac set to
    /// German with Croatian as a secondary preference must still get Croatian, not fall through
    /// to English because German is neither. No match anywhere in the list -> English, never
    /// Croatian as a silent fallback: someone on an unrelated system language must get clean
    /// English. Hand-tested against a literal table in scripts/locale-selftest.swift (launcher
    /// pattern: compiles this file standalone).
    static func resolveSystem(_ preferredLanguages: [String]) -> String {
        for lang in preferredLanguages {
            if lang.hasPrefix("hr") { return "hr" }
            if lang.hasPrefix("en") { return "en" }
        }
        return "en"
    }

    /// Locale for every DateFormatter / RelativeDateTimeFormatter / FormatStyle in the app.
    static var current: Locale {
        Locale(identifier: languageCode == "hr" ? "hr_HR" : "en_GB")
    }

    /// Gregorian calendar in the user's time zone with the app locale (Monday-first for both).
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.locale = current
        c.firstWeekday = 2
        return c
    }
}
