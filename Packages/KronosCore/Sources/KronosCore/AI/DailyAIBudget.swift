// `AIClient` carries no provider-identity field (see Contracts/AI.swift), so "is this call
// metered" is decided by concrete client type: `ClaudeCodeClient` is Anthropic's API under
// the hood (its own header comment: "Data leaves the Mac (Anthropic's API, same as any other
// hosted provider)") — the only metered surface this app has today. See the internal notes §3.4
// ("Paid budget (resolves ai-10)").
//
// Persisted as `{day: "yyyy-MM-dd", paidCalls: N}` in `KronosEnv.defaults` — already the
// hermetic-aware shared-defaults seam every other persisted preference in this app goes
// through (its own doc comment: "Every persisted flag or value of new code goes through
// KronosEnv.defaults"), standing in for the spec's "App Group defaults": this app has no
// separate App Group container (no widget/share extension), so the single shared suite is
// the real equivalent here. Reset happens lazily: any read or write that notices the stored
// day no longer matches today zeroes the counter first, same as the spec's "reset on day
// change" with no separate reset job to run or forget to run.
//
// `UserDefaults` is internally thread-safe, so every method here is a plain get/set with no
// extra locking — the same "no state besides UserDefaults" shape as `CustomSoundPrefs`'s
// `key(_ cue:)` + `defaults` pair (Kronos/Settings/CustomSoundPrefs.swift), just without a
// hermetic scratch suite of its own: `KronosEnv.defaults` already resolves that.

import Foundation

public enum DailyAIBudget {
    /// Anthropic is metered at ~$0.60/day at Haiku 4.5 rates for 200 calls (spec §3.4).
    public static let defaultCeiling = 200

    private static let dayKey = "kronos.ai.budget.day"
    private static let countKey = "kronos.ai.budget.paidCalls"
    private static let toastShownDayKey = "kronos.ai.budget.toastShownDay"

    private static func dayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Rolls the counter to 0 first if the stored day no longer matches `now`'s day, then
    /// returns today's count. Every other method here goes through this, so a day change is
    /// always caught on next use regardless of which method is called first.
    private static func countRollingOver(now: Date) -> Int {
        let today = dayString(now)
        guard KronosEnv.defaults.string(forKey: dayKey) == today else {
            KronosEnv.defaults.set(today, forKey: dayKey)
            KronosEnv.defaults.set(0, forKey: countKey)
            return 0
        }
        return KronosEnv.defaults.integer(forKey: countKey)
    }

    /// Today's paid-call count so far, rolling the day over first if needed.
    public static func countToday(now: Date = Date()) -> Int {
        countRollingOver(now: now)
    }

    /// Records one metered call against today's count. Call once per actual `send()` attempt
    /// to a metered client — see `AIRouter.hopAcrossModels` / `AIRouter.extractTasks`.
    public static func increment(now: Date = Date()) {
        let today = dayString(now)
        let current = countRollingOver(now: now)
        KronosEnv.defaults.set(today, forKey: dayKey)
        KronosEnv.defaults.set(current + 1, forKey: countKey)
    }

    /// True once today's count has reached `limit` (default 200): metered candidates become
    /// ineligible for the rest of the day and the deterministic path is used instead.
    public static func isAtCeiling(limit: Int = defaultCeiling, now: Date = Date()) -> Bool {
        countToday(now: now) >= limit
    }

    /// True exactly once per day: the first caller this day gets `true` and flips the stored
    /// flag; every later call the same day gets `false`. `AIRouter.eligibleCandidates` calls
    /// this only right after it has actually dropped a metered candidate, so the single
    /// non-blocking toast fires at most once per day and only when the ceiling really bit.
    public static func shouldShowCeilingToast(now: Date = Date()) -> Bool {
        let today = dayString(now)
        guard KronosEnv.defaults.string(forKey: toastShownDayKey) != today else { return false }
        KronosEnv.defaults.set(today, forKey: toastShownDayKey)
        return true
    }

    /// A 30-day rolling estimate is not literally derivable from a single day-keyed counter
    /// with no retained history — this is a documented approximation (today's count
    /// extrapolated flat across 30 days), matching the spec's own "today's count and a 30-day
    /// rolling estimate" without inventing a second, heavier per-day history store for it.
    public static func estimated30Day(now: Date = Date()) -> Int {
        countToday(now: now) * 30
    }
}
